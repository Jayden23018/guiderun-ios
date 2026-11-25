import XCTest
@testable import blindRun

/// #1010：通话这一步的取消入口，和陪跑员端「本轮结束后取详情失败」的判法。
@MainActor
final class IntroCallCancelAndRoundResolveTests: XCTestCase {
    // MARK: - #1010 通话这一步的取消入口

    /// 「···」里要有取消，且排在「更换陪跑员」后面；两个标签读起来要分得开。
    func testIntroCallMenuOffersCancelBookingSeparateFromChangeVolunteer() {
        XCTAssertEqual(BlindIntroCallMenu.kinds(for: .pendingIntroCall), [.changeVolunteer, .cancelBooking])
        XCTAssertNotEqual(BlindOrderStageCopy.cancelIntroCallBooking, IntroCallCopy.declineButtonTitle)
        XCTAssertTrue(BlindOrderStageCopy.cancelIntroCallBooking.contains("取消"))
        XCTAssertFalse(BlindOrderStageCopy.cancelIntroCallBooking.contains("更换"))
    }

    /// #1010：本轮结束后取订单详情**没拿到**（网络失败 / 5xx / 解码失败）≠ 没约成。
    /// 只有服务端明说不是参与者（403 / 409）才判 `.closed`；其余留在 `.active`，下一轮轮询再判。
    func testVolunteerKeepsTheRoundOpenWhenOrderDetailFailsToLoad() async {
        struct Boom: Error {}
        let transient: [APIError] = [.networkError(Boom()), .unknown(statusCode: 503), .decodingError(Boom())]
        for (index, failure) in transient.enumerated() {
            let safety = FakeSafetyService()
            safety.introCallResult = .failure(
                APIError.serverError(ErrorResponse(code: "INTRO_CALL_NOT_ACTIVE", message: "这一轮通话已经结束了"))
            )
            safety.matchedOrderResult = .failure(failure)
            let appState = AppState(safety: safety)
            let viewModel = VolunteerIntroCallViewModel()
            let speech = SpeechService()
            viewModel.configure(orderId: 700 + Int64(index), appState: appState, speechService: speech)
            speech.resetSpokenHistoryForTesting()

            await viewModel.refresh()

            XCTAssertEqual(viewModel.outcome, .active, "\(failure) 只是这次没拿到，不是没约成")
            XCTAssertFalse(speech.spokenHistoryForTesting.contains(IntroCallCopy.volunteerRoundClosed))

            // 网络恢复后的下一轮轮询：订单读得到 ⇒ 成了。
            safety.matchedOrderResult = .success(.preview(orderId: 700 + Int64(index), status: .pendingAccept))
            await viewModel.refresh()
            XCTAssertEqual(viewModel.outcome, .matched)
        }
    }
}
