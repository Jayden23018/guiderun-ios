import XCTest
@testable import blindRun

/// 跑者让陪跑员的手机响（后端 #1046，iOS #1023）。
///
/// 钉的是声音之前的每一步：事件分流、响多久、不响两遍、文案不混用、按钮的结果与冷却。
/// 声音够不够大、震不震，只能真机人耳验；单测未在真机实跑，见 PR 交接。
@MainActor
final class VolunteerRingTests: XCTestCase {

    private let formatter = DateFormatter.aidRunBackendLocalDateTime
    private let sentAt = Date(timeIntervalSince1970: 1_790_000_000)

    private func ring(
        eventType: String = "VOLUNTEER_RING",
        messageId: String? = "vring-1",
        until: String?
    ) -> WSAppNotification {
        WSAppNotification(
            type: WSMessageType.appNotification.rawValue,
            eventId: nil,
            messageId: messageId,
            eventType: eventType,
            title: nil,
            body: "后端正文",
            ttsText: "后端口播",
            priority: "HIGH",
            timestamp: formatter.string(from: sentAt),
            orderId: 7,
            until: until
        )
    }

    private func until(after seconds: TimeInterval) -> String {
        formatter.string(from: sentAt.addingTimeInterval(seconds))
    }

    // MARK: - 陪跑员端：事件分流

    func testVolunteerRingEventsMapToTheirOwnKinds() {
        XCTAssertEqual(RunnerRingRequest.Kind(eventType: "VOLUNTEER_RING"), .runnerSeeking)
        XCTAssertEqual(RunnerRingRequest.Kind(eventType: "volunteer_ring_lost"), .runnerLost)
        XCTAssertTrue(RunnerRingRequest.Kind.runnerSeeking.isForVolunteer)
        XCTAssertTrue(RunnerRingRequest.Kind.runnerLost.isForVolunteer)
        XCTAssertFalse(RunnerRingRequest.Kind.arrived.isForVolunteer)
        XCTAssertFalse(RunnerRingRequest.Kind.lost.isForVolunteer)
    }

    func testVolunteerSessionRingsFromServerUntilNotFromAnInventedDuration() throws {
        let request = try XCTUnwrap(RunnerRingRequest.make(from: ring(until: until(after: 10)), receivedAt: sentAt))
        XCTAssertEqual(request.kind, .runnerSeeking)
        XCTAssertEqual(request.speechText, "后端口播")
        XCTAssertEqual(request.endsAt.timeIntervalSince(sentAt), 10, accuracy: 0.01)
    }

    func testVolunteerSessionRingsAndDoesNotFallToTheBanner() async {
        let coordinator = AppRealtimeCoordinator(now: { [sentAt] in sentAt }, notificationDuration: 60)
        let service = WebSocketService()
        coordinator.attach(to: service, role: .volunteer)

        service.simulateIncomingEventForTesting(.notification(ring(until: until(after: 10))))
        await Task.yield()

        XCTAssertEqual(coordinator.runnerRing?.id, "vring-1")
        XCTAssertEqual(coordinator.runnerRing?.kind, .runnerSeeking)
        XCTAssertNil(coordinator.currentNotification, "落到横幅 = 只念一次、不响")
    }

    func testLostVariantRingsAsRunnerLost() async {
        let coordinator = AppRealtimeCoordinator(now: { [sentAt] in sentAt }, notificationDuration: 60)
        let service = WebSocketService()
        coordinator.attach(to: service, role: .volunteer)

        service.simulateIncomingEventForTesting(.notification(ring(eventType: "VOLUNTEER_RING_LOST", until: until(after: 10))))
        await Task.yield()

        XCTAssertEqual(coordinator.runnerRing?.kind, .runnerLost)
    }

    /// 跑者端不许响陪跑员那一种（对称地，陪跑员端不响 `RUNNER_RING`，见 `RunnerVolunteerActionsTests`）。
    func testBlindSessionNeverRingsForTheVolunteerEvent() async {
        let coordinator = AppRealtimeCoordinator(now: { [sentAt] in sentAt }, notificationDuration: 60)
        let service = WebSocketService()
        coordinator.attach(to: service, role: .blind)

        service.simulateIncomingEventForTesting(.notification(ring(until: until(after: 10))))
        await Task.yield()

        XCTAssertNil(coordinator.runnerRing)
    }

    /// 同一条 WS 重复投递（重连补读）只响一次。
    func testRepeatedDeliveryOfTheSameMessageRingsOnce() async {
        let coordinator = AppRealtimeCoordinator(now: { [sentAt] in sentAt }, notificationDuration: 60)
        let service = WebSocketService()
        coordinator.attach(to: service, role: .volunteer)

        service.simulateIncomingEventForTesting(.notification(ring(until: until(after: 10))))
        await Task.yield()
        coordinator.dismissRunnerRing()
        service.simulateIncomingEventForTesting(.notification(ring(until: until(after: 10))))
        await Task.yield()

        XCTAssertNil(coordinator.runnerRing, "同一个 messageId 在去重窗口里不许再响一遍")
    }

    func testRingWithoutUntilOrAlreadyPastDoesNotRing() {
        XCTAssertNil(RunnerRingRequest.make(from: ring(until: nil), receivedAt: sentAt))
        XCTAssertNil(RunnerRingRequest.make(from: ring(until: until(after: -5)), receivedAt: sentAt))
    }

    // MARK: - 文案：两句话不能混用

    func testCopyDiffersByPhaseAndNeverSaysTheWrongPlace() {
        let seeking = RunnerRingRequest.Kind.runnerSeeking
        let lost = RunnerRingRequest.Kind.runnerLost
        XCTAssertEqual(RunnerRingCopy.fallbackSpeech(seeking), "跑者在找你，请出声回应")
        XCTAssertEqual(RunnerRingCopy.fallbackSpeech(lost), "跑者找不到你，请原地出声回应")
        XCTAssertNotEqual(RunnerRingCopy.title(seeking), RunnerRingCopy.title(lost))
        XCTAssertNotEqual(RunnerRingCopy.detail(seeking), RunnerRingCopy.detail(lost))
        for kind in [seeking, lost] {
            for text in [RunnerRingCopy.title(kind), RunnerRingCopy.detail(kind), RunnerRingCopy.accessibilityLabel(kind)] {
                XCTAssertFalse(text.contains("你的陪跑员"), "陪跑员端不能念跑者端那句：\(text)")
                XCTAssertFalse(text.contains("到了"), text)
            }
            XCTAssertEqual(RunnerRingCopy.stopTitle(kind), "知道了")
        }
        XCTAssertEqual(RunnerRingCopy.stopTitle(.arrived), "停止响铃", "跑者端现有文案不动")
    }

    // MARK: - 起止、震动

    private final class Recorder {
        var events: [String] = []
    }

    private func controller(_ recorder: Recorder) -> RunnerRingController {
        let controller = RunnerRingController()
        controller.speak = { recorder.events.append("speak:\($0)") }
        controller.isSpeaking = { false }
        controller.startTone = { recorder.events.append("start") }
        controller.stopTone = { recorder.events.append("stop") }
        controller.vibrate = { recorder.events.append("vibrate") }
        controller.onFinish = { recorder.events.append("finish") }
        return controller
    }

    private func request(kind: RunnerRingRequest.Kind, lasting seconds: TimeInterval) -> RunnerRingRequest {
        RunnerRingRequest(id: "c-\(kind)", orderId: 7, speechText: "找你", endsAt: Date().addingTimeInterval(seconds), kind: kind)
    }

    func testVolunteerRingVibratesWhileRingingAndStopsAtTheDeadline() async throws {
        let recorder = Recorder()
        let controller = controller(recorder)
        controller.handle(request(kind: .runnerSeeking, lasting: 0.4))
        try await Task.sleep(nanoseconds: 150_000_000)
        XCTAssertTrue(recorder.events.contains("vibrate"))
        XCTAssertNotNil(controller.active)

        try await Task.sleep(nanoseconds: 1_400_000_000)
        XCTAssertNil(controller.active, "到点（后端下发的 until）自己停")
        XCTAssertEqual(recorder.events.last, "finish")
        let vibrations = recorder.events.filter { $0 == "vibrate" }.count
        try await Task.sleep(nanoseconds: 1_200_000_000)
        XCTAssertEqual(recorder.events.filter { $0 == "vibrate" }.count, vibrations, "停了之后不许再震")
    }

    func testAcknowledgeStopsToneAndVibration() async throws {
        let recorder = Recorder()
        let controller = controller(recorder)
        controller.handle(request(kind: .runnerLost, lasting: 5))
        try await Task.sleep(nanoseconds: 150_000_000)
        controller.stop()
        XCTAssertNil(controller.active)
        XCTAssertEqual(Array(recorder.events.suffix(2)), ["stop", "finish"])
        let vibrations = recorder.events.filter { $0 == "vibrate" }.count
        try await Task.sleep(nanoseconds: 1_200_000_000)
        XCTAssertEqual(recorder.events.filter { $0 == "vibrate" }.count, vibrations)
    }

    func testBlindRingDoesNotVibrate() async throws {
        let recorder = Recorder()
        let controller = controller(recorder)
        controller.handle(request(kind: .arrived, lasting: 0.3))
        try await Task.sleep(nanoseconds: 500_000_000)
        XCTAssertFalse(recorder.events.contains("vibrate"), "跑者端现有行为不改")
    }

    // MARK: - 推送与 WS 不响两遍

    func testPushRingEventsAreRecognisedByEventTypeOnly() {
        XCTAssertTrue(VolunteerRingPush.isRingEvent(["eventType": "VOLUNTEER_RING"]))
        XCTAssertTrue(VolunteerRingPush.isRingEvent(["eventType": "VOLUNTEER_RING_LOST", "recipientUserId": 9]))
        XCTAssertFalse(VolunteerRingPush.isRingEvent(["eventType": "RUNNER_RING"]), "跑者端的推送不归这一条管")
        XCTAssertFalse(VolunteerRingPush.isRingEvent(["eventType": "ORDER_ACCEPTED"]))
        XCTAssertFalse(VolunteerRingPush.isRingEvent([:]))
    }

    /// WS 掉线时推送是唯一通道，不能吞（否则跑者听到「正在响」而陪跑员什么都没有）。
    func testForegroundPushIsSwallowedOnlyWhileTheSocketIsUp() {
        let push: [AnyHashable: Any] = ["eventType": "VOLUNTEER_RING"]
        XCTAssertTrue(VolunteerRingPush.suppressesForeground(push, isWebSocketConnected: true))
        XCTAssertFalse(VolunteerRingPush.suppressesForeground(push, isWebSocketConnected: false))
        XCTAssertFalse(VolunteerRingPush.suppressesForeground(["eventType": "ORDER_ACCEPTED"], isWebSocketConnected: true))
    }

}

// 跑者端的按钮放在扩展里：类体到了 SwiftLint 的 250 行上限（棘轮 #488）。
@MainActor
extension VolunteerRingTests {
    // MARK: - 跑者端：接口与按钮

    func testEndpointShape() {
        let request = OrderEndpoint.ringVolunteer(orderId: 7).request
        XCTAssertEqual(request.path, "/api/orders/7/ring-volunteer")
        XCTAssertEqual(request.method, .post)
    }

    func testButtonIsOfferedOnlyWhereTheBackendAllows() {
        XCTAssertTrue(BlindRingVolunteerCopy.isAvailable(in: .driverArrived))
        XCTAssertTrue(BlindRingVolunteerCopy.isAvailable(in: .inProgress))
        XCTAssertFalse(BlindRingVolunteerCopy.isAvailable(in: .driverEnRoute), "陪跑员还在路上，后端 409")
        XCTAssertFalse(BlindRingVolunteerCopy.isAvailable(in: .pendingAccept))
        XCTAssertFalse(BlindRingVolunteerCopy.isAvailable(in: .completed))
    }

    private final class Speech {
        var spoken: [String] = []
        var errors: [String] = []
    }

    /// 按钮背后那次请求：脚本化的结果加调用计数。
    private final class Sender {
        var result: Result<OrderNudgeResponse, Error>
        var calls = 0
        init(_ result: Result<OrderNudgeResponse, Error>) { self.result = result }
    }

    private func ring(
        _ model: BlindRingVolunteerViewModel,
        sender: Sender,
        speech: Speech,
        now: Date = Date()
    ) async {
        await model.ring(
            orderId: 7,
            now: now,
            send: { _ in
                sender.calls += 1
                return try sender.result.get()
            },
            speak: { speech.spoken.append($0) },
            speakError: { speech.errors.append($0) }
        )
    }

    private func response(until: String?, delivered: Bool?) -> OrderNudgeResponse {
        OrderNudgeResponse(success: true, orderId: 7, ringingUntil: until, delivered: delivered)
    }

    func testSuccessUsesTheBackendDeadlineAndBlocksUntilThen() async throws {
        let speech = Speech()
        let sender = Sender(.failure(URLError(.badURL)))
        let model = BlindRingVolunteerViewModel()
        // 后端的时间串精度有限：期望值按同一格式取整，比的是「没加秒数」而不是毫秒。
        let sent = formatter.string(from: Date().addingTimeInterval(10))
        let deadline = try XCTUnwrap(sent.backendTimestamp)
        sender.result = .success(response(until: sent, delivered: true))

        await ring(model, sender: sender, speech: speech)

        XCTAssertEqual(sender.calls, 1)
        XCTAssertEqual(speech.spoken, [BlindRingVolunteerCopy.success])
        XCTAssertNil(model.notice)
        let until = try XCTUnwrap(model.ringingUntil)
        XCTAssertEqual(until.timeIntervalSince(deadline), 0, accuracy: 0.001, "客户端不自己加秒数")
        XCTAssertTrue(model.isRinging(at: deadline.addingTimeInterval(-5)))
        XCTAssertFalse(model.isRinging(at: deadline.addingTimeInterval(0.5)), "到点自己恢复可按")

        await ring(model, sender: sender, speech: speech)
        XCTAssertEqual(sender.calls, 1, "响铃期间再按不发请求")
    }

    func testNotDeliveredSaysSoAndDoesNotLockTheButton() async {
        let speech = Speech()
        let sender = Sender(.failure(URLError(.badURL)))
        let model = BlindRingVolunteerViewModel()
        sender.result = .success(response(until: formatter.string(from: Date().addingTimeInterval(10)), delivered: false))

        await ring(model, sender: sender, speech: speech)

        XCTAssertEqual(model.notice, BlindRingVolunteerCopy.notDelivered)
        XCTAssertEqual(speech.errors, [BlindRingVolunteerCopy.notDelivered])
        XCTAssertTrue(speech.spoken.isEmpty, "没送到不能念成功")
        XCTAssertFalse(model.isRinging(at: Date()))
    }

    /// 限频念后端的 `message`，不自己拼，也不接 `localizedMessage` 后面那句「请在N秒后重试」。
    func testRateLimitReadsTheBackendMessageVerbatim() async {
        let speech = Speech()
        let sender = Sender(.failure(URLError(.badURL)))
        let model = BlindRingVolunteerViewModel()
        sender.result = .failure(APIError.rateLimited(RateLimitInfo(message: "后端说：请稍等", retryAfterSeconds: 10)))

        await ring(model, sender: sender, speech: speech)

        XCTAssertEqual(model.notice, "后端说：请稍等")
        XCTAssertEqual(speech.errors, ["后端说：请稍等"])
        XCTAssertFalse(model.isRinging(at: Date()))
    }

    func testOtherFailuresAreShownAndSpoken() async {
        let speech = Speech()
        let sender = Sender(.failure(URLError(.badURL)))
        let model = BlindRingVolunteerViewModel()
        let conflict = APIError.serverError(ErrorResponse(code: "ORDER_STATUS_NOT_ALLOWED", message: "当前订单状态不允许该操作"))
        sender.result = .failure(conflict)
        await ring(model, sender: sender, speech: speech)
        XCTAssertEqual(model.notice, conflict.localizedMessage)
        XCTAssertEqual(speech.errors, [conflict.localizedMessage])

        sender.result = .failure(URLError(.notConnectedToInternet))
        await ring(model, sender: sender, speech: speech)
        XCTAssertEqual(model.notice, BlindRingVolunteerCopy.failed)
    }

    func testSuccessClearsAnEarlierNotice() async {
        let speech = Speech()
        let sender = Sender(.failure(URLError(.badURL)))
        let model = BlindRingVolunteerViewModel()
        sender.result = .failure(URLError(.timedOut))
        await ring(model, sender: sender, speech: speech)
        XCTAssertNotNil(model.notice)

        sender.result = .success(response(until: formatter.string(from: Date().addingTimeInterval(10)), delivered: true))
        await ring(model, sender: sender, speech: speech)
        XCTAssertNil(model.notice)
    }
}
