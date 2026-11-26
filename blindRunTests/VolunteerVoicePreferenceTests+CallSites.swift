import CoreLocation
import SwiftUI
import XCTest
@testable import blindRun

/// 陪跑员关着 App 语音时，各个接线点和调用点照念的、该静音的（backend#1064）。
/// 单独成文件：`VolunteerVoicePreferenceTests.swift` 到了类体长度上限。辅助方法在那个文件里。
extension VolunteerVoicePreferenceTests {

    // MARK: - 根视图接线

    /// 删掉根视图上的 `VolunteerVoiceGate`，或根视图念通知时不带标记，这条会红。
    func testRootViewWiresTheGateAndSpeaksKeptNotifications() async throws {
        let saved = UserDefaults.standard.object(forKey: VolunteerVoicePreference.defaultsKey)
        UserDefaults.standard.removeObject(forKey: VolunteerVoicePreference.defaultsKey)
        defer { UserDefaults.standard.set(saved, forKey: VolunteerVoicePreference.defaultsKey) }
        let appState = makeAppState(role: nil)
        let speech = SpeechService()
        speech.isCallActive = { false }
        let window = host(
            ContentView()
                .environmentObject(appState)
                .environmentObject(speech)
                .environmentObject(SpeechInputService())
                .environmentObject(LocationService())
                .environmentObject(AMapGeocodingService())
        )
        defer { window.isHidden = true }
        try await settle()

        appState.activeRole = .volunteer
        XCTAssertTrue(speech.isRoutineSpeechSilenced(), "根视图没把开关接到播报器上")
        try await settle()
        appState.realtimeCoordinator.simulateIncomingEventForTesting(
            .notification(notification("RUNNER_BATTERY_LOW", body: "跑者手机电量低"))
        )
        try await settle()

        XCTAssertTrue(speech.spokenHistoryForTesting.contains("跑者手机电量低"), "\(speech.spokenHistoryForTesting)")
    }

    /// 跑者让陪跑员的手机响：关着语音也要念那一句。
    func testRunnerRingIsSpokenForASilencedVolunteer() async throws {
        let appState = makeVolunteerAppState()
        let speech = makeSilencedSpeech()
        let window = host(
            Color.clear.volunteerFindMeRing().environmentObject(appState).environmentObject(speech)
        )
        defer { window.isHidden = true }
        try await settle()

        appState.realtimeCoordinator.simulateIncomingEventForTesting(.notification(
            notification("VOLUNTEER_RING", body: "跑者在出发点找你", until: Date().addingTimeInterval(3))
        ))
        try await settle()

        XCTAssertEqual(speech.spokenHistoryForTesting, ["跑者在出发点找你"])
    }

    // MARK: - 推送朗读

    func testPushReadAloudKeepsOnlySafetyEventsForASilencedVolunteer() async {
        let appState = makeAppState(role: .volunteer)
        appState.accessToken = "test-token"
        appState.sessionRestorationState = .authenticated
        let speech = makeSilencedSpeech()
        let push = PushNotificationsManager()
        push.registrar = .inert
        push.configure(appState: appState, speechService: speech)

        await push.announce("普通订单消息", userInfo: ["eventType": "ORDER_ACCEPTED"], restorationWait: 0)
        await push.announce("你和跑者走散了", userInfo: ["eventType": "ESCORT_DISTANCE_ALERT"], restorationWait: 0)

        XCTAssertEqual(speech.spokenHistoryForTesting, ["你和跑者走散了"])
    }

    // MARK: - 陪跑员页面上照念的几句

    func testSilencedVolunteerStillHearsTheKilometerToggleHeTurnedOn() {
        let speech = makeSilencedSpeech()
        let viewModel = VolunteerInServiceViewModel(voiceBroadcastEnabled: { true })
        viewModel.configure(with: makeVolunteerAppState(), speechService: speech, initialOrder: nil)

        viewModel.announceKilometerIfNeeded(TrackStats(distanceMeters: 1_200, durationSeconds: 463, avgPaceSecPerKm: 386))
        viewModel.announceKilometerIfNeeded(TrackStats(distanceMeters: 2_010, durationSeconds: 900, avgPaceSecPerKm: 448))

        XCTAssertEqual(speech.spokenHistoryForTesting, ["2 公里，用时 15 分 0 秒"])
    }

    func testSilencedVolunteerHearsThatTheEmergencyWasNotSent() async {
        let speech = makeSilencedSpeech()
        // 页面对 AppState 是弱引用：不在本地持有，真机上它当场被释放，页面在 guard 处提前返回。
        let appState = makeVolunteerAppState()
        let viewModel = makePage(appState, speech)

        await viewModel.enterEmergency(locate: { nil }, locationFailureReason: { .preciseLocationOff })

        XCTAssertEqual(speech.spokenHistoryForTesting.count, 1)
        appState.emergencyCoordinator.reset()
    }

    func testSilencedVolunteerHearsThatTheEmergencyWasSent() async {
        let safety = FakeSafetyService()
        safety.triggerEmergencyResult = .success(EmergencyTriggerResponse(success: true, eventId: 9, status: "PENDING"))
        let appState = makeVolunteerAppState(safety: safety)
        let speech = makeSilencedSpeech()
        let viewModel = makePage(appState, speech)
        let location = LocationService()
        location.simulateDeviceLocationForTesting(
            CLLocationCoordinate2D(latitude: 31.2304, longitude: 121.4737), capturedAt: Date(), horizontalAccuracy: 10
        )
        let sample = location.latestBackendSample()

        await viewModel.enterEmergency(locate: { sample })

        XCTAssertFalse(appState.emergencyCoordinator.state.isFailure, "前提：走的是成功那一支")
        XCTAssertEqual(speech.spokenHistoryForTesting.count, 1)
        appState.emergencyCoordinator.reset()
    }

    func testSilencedVolunteerHearsBothEmergencyAcknowledgeResults() async {
        for succeeds in [true, false] {
            let safety = FakeSafetyService()
            if succeeds {
                safety.acknowledgeEmergencyResult = .success(
                    VolunteerEmergencyAcknowledgement(success: true, eventId: 77, action: "NEED_HELP")
                )
            }
            let speech = makeSilencedSpeech()
            // 页面对 AppState 是弱引用：不在本地持有，真机上它当场被释放，页面在 guard 处提前返回。
            let appState = makeVolunteerAppState(safety: safety)
            let viewModel = makePage(appState, speech)

            await viewModel.acknowledgeEmergency(eventID: 77)

            XCTAssertEqual(speech.spokenHistoryForTesting.count, 1, "succeeds=\(succeeds)")
            withExtendedLifetime(appState) {}
        }
    }

    func testSilencedVolunteerHearsThatFinishingWaitsForTheRunner() async {
        let speech = makeSilencedSpeech()
        let viewModel = makePage(makeVolunteerAppState(), speech)

        await viewModel.recordFinishAwaitingBlind(VolunteerFinishAwaitingBlind(opensAt: nil), orderID: 7)

        XCTAssertEqual(speech.spokenHistoryForTesting, [FinishSafetyCopy.volunteerRequested(opensAt: nil)])
    }

    func testSilencedVolunteerHearsThatTheRunnersPhoneWasNotReached() async {
        let orders = FakeOrderService()
        orders.ringRunnerResult = .success(OrderNudgeResponse(
            success: true, orderId: 7,
            ringingUntil: DateFormatter.aidRunBackendLocalDateTime.string(from: Date().addingTimeInterval(10)),
            delivered: false
        ))
        let speech = makeSilencedSpeech()
        let appState = makeVolunteerAppState(orders: orders)
        let viewModel = makePage(appState, speech)

        await viewModel.ringRunner()

        XCTAssertEqual(speech.spokenHistoryForTesting, ["对方可能没收到，可以打电话。"])
        withExtendedLifetime(appState) {}
    }

    /// 证书页进页和上传后的自动播报要静音，只有「重复当前状态」照念。
    func testCertificatePageIsSilentUnlessTheVolunteerAsks() async {
        let speech = makeSilencedSpeech()
        let viewModel = VolunteerCertificateUploadViewModel()
        viewModel.configure(with: makeVolunteerAppState(), speechService: speech)

        await viewModel.refreshStatus(announce: true)
        XCTAssertEqual(speech.spokenHistoryForTesting, [])

        viewModel.announceCurrentStatus(essential: true)
        XCTAssertEqual(speech.spokenHistoryForTesting, [viewModel.statusAnnouncement])
    }

    // MARK: - 同行位置共享

    func testOnlyDegradedEscortHealthKeepsSpeech() {
        XCTAssertFalse(LiveEscortHealthState.idle.isDegraded)
        XCTAssertFalse(LiveEscortHealthState.active(background: false).isDegraded)
        XCTAssertFalse(LiveEscortHealthState.active(background: true).isDegraded)
        XCTAssertTrue(LiveEscortHealthState.waitingForLocation.isDegraded)
        XCTAssertTrue(LiveEscortHealthState.permissionRequired.isDegraded)
        XCTAssertTrue(LiveEscortHealthState.networkDisconnected.isDegraded)
    }
}
