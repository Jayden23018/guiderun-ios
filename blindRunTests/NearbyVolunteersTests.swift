import XCTest
@testable import blindRun

/// #1046：约跑页「目前附近无志愿者」提示卡。
@MainActor
final class NearbyVolunteersTests: XCTestCase {

    private let hint = "出发点 20 公里内暂时没有可接单的陪跑员。"

    // MARK: - 解码与显示判定

    func testDecodesTheEnvelopeFromTheContract() throws {
        let json = #"{"success":true,"code":200,"message":"ok","data":{"hasNearbyVolunteers":false,"radiusKm":20,"hint":"附近暂时没人"}}"#
        let response = try APIPayloadDecoder.decodePayload(
            NearbyVolunteersResponse.self, from: Data(json.utf8), decoder: JSONDecoder()
        )
        XCTAssertEqual(response, NearbyVolunteersResponse(hasNearbyVolunteers: false, radiusKm: 20, hint: "附近暂时没人"))
    }

    func testNoCardWhenTheHintIsNullOrBlank() {
        XCTAssertNil(NearbyVolunteersNotice(response(has: false, hint: nil)))
        XCTAssertNil(NearbyVolunteersNotice(response(has: false, hint: "  ")))
    }

    /// 有人时绝不说「附近无志愿者」，哪怕后端带了一句话。
    func testNoCardWhenThereAreVolunteers() {
        XCTAssertNil(NearbyVolunteersNotice(response(has: true, hint: hint)))
    }

    func testCardReadsAsOneSentenceWithTheServerHint() throws {
        let notice = try XCTUnwrap(NearbyVolunteersNotice(response(has: false, hint: hint)))
        XCTAssertEqual(notice.hint, hint)
        XCTAssertEqual(notice.spokenLabel, "提示，目前附近无志愿者。\(hint)")
    }

    // MARK: - 主动播报

    /// 开场白还没念完：先说没人，再接按此刻选择重拼的开场白。
    func testSpeaksTheNoticeFirstAndRepeatsTheInterruptedEntry() throws {
        let (form, speech, notice) = try makeSpeechForm()
        speech.speak("进页开场白")

        form.viewModel.speakNearbyVolunteersNotice(notice, spokenEntry: "进页开场白", currentEntry: "新开场白")

        XCTAssertEqual(speech.lastSpokenText, "目前附近无志愿者。\(hint)新开场白")
    }

    /// 没有正在念的话（定位回来得晚）：只说没人，不重念开场白。
    func testSpeaksOnlyTheNoticeWhenNothingIsPlaying() throws {
        let (form, speech, notice) = try makeSpeechForm()

        form.viewModel.speakNearbyVolunteersNotice(notice, spokenEntry: "进页开场白", currentEntry: "新开场白")

        XCTAssertEqual(speech.lastSpokenText, "目前附近无志愿者。\(hint)")
    }

    /// 正在念别的话（例如添加页的「已收藏」确认）：原样接在后面，不能吞掉。
    func testKeepsAnotherInterruptedSentenceAfterTheNotice() throws {
        let (form, speech, notice) = try makeSpeechForm()
        speech.speak("已收藏操场，之后默认从这里出发。")

        form.viewModel.speakNearbyVolunteersNotice(notice, spokenEntry: "进页开场白", currentEntry: "新开场白")

        XCTAssertEqual(speech.lastSpokenText, "目前附近无志愿者。\(hint)已收藏操场，之后默认从这里出发。")
    }

    /// 连着换出发点：上一个出发点的「没人」不许叠着重念。
    func testDoesNotRepeatTheNoticeOfThePreviousStartPlace() throws {
        let (form, speech, notice) = try makeSpeechForm()
        speech.speak("目前附近无志愿者。上一个出发点的话。")

        form.viewModel.speakNearbyVolunteersNotice(notice, spokenEntry: "进页开场白", currentEntry: "新开场白")

        XCTAssertEqual(speech.lastSpokenText, "目前附近无志愿者。\(hint)")
    }

    // MARK: - 查询时机

    func testShowsTheCardForTheSelectedStartPlace() async {
        let form = makeForm()
        form.orders.nearby.result = .success(response(has: false, hint: hint))

        await form.viewModel.refreshNearbyVolunteers()

        XCTAssertEqual(form.viewModel.nearbyVolunteersNotice?.hint, hint)
        XCTAssertEqual(form.orders.nearby.lastCoordinate, [31.2304, 121.4737])
    }

    func testRequestFailureShowsNothingAndDoesNotSetAnError() async {
        let form = makeForm()
        form.orders.nearby.result = .failure(APIError.serverError(ErrorResponse(code: "HTTP_404", message: "Not Found")))

        await form.viewModel.refreshNearbyVolunteers()

        XCTAssertEqual(form.orders.callCount("nearbyVolunteers(latitude:longitude:)"), 1)
        XCTAssertNil(form.viewModel.nearbyVolunteersNotice)
        XCTAssertNil(form.viewModel.errorMessage, "只是提示：查不到不许冒出报错")
    }

    /// 当前定位漂移不重查；离**上次查询点**满 1 公里或换了地点才查。纬度差 0.0081 ≈ 900 米，0.0099 ≈ 1100 米。
    func testQueriesAgainOnlyWhenTheStartPointChanges() async {
        let form = makeForm()
        form.viewModel.selectedStartPlace = nil
        form.orders.nearby.result = .success(response(has: false, hint: hint))

        for latitude in [31.2304, 31.2358, 31.2385] {
            form.viewModel.currentResolvedPlace = place(id: "amap-\(latitude)", latitude: latitude, source: .deviceLocation)
            await form.viewModel.refreshNearbyVolunteers()
        }
        XCTAssertEqual(form.orders.callCount("nearbyVolunteers(latitude:longitude:)"), 1, "900 米以内算同一个出发点")

        form.viewModel.currentResolvedPlace = place(id: "device-current", latitude: 31.2403, source: .deviceLocation)
        await form.viewModel.refreshNearbyVolunteers()
        XCTAssertEqual(form.orders.callCount("nearbyVolunteers(latitude:longitude:)"), 2, "离上次查询点约 1100 米")

        form.viewModel.selectedStartPlace = place(id: "poi-2", latitude: 31.2403, source: .manual)
        await form.viewModel.refreshNearbyVolunteers()
        XCTAssertEqual(form.orders.callCount("nearbyVolunteers(latitude:longitude:)"), 3, "换成了选定的地点")
    }

    /// 换地点：新结果还没回来时旧卡就得撤掉。
    func testChangingTheStartPlaceDropsTheOldCardBeforeTheNewAnswerArrives() async {
        let form = makeForm()
        let viewModel = form.viewModel
        form.orders.nearby.result = .success(response(has: false, hint: hint))
        await viewModel.refreshNearbyVolunteers()
        XCTAssertNotNil(viewModel.nearbyVolunteersNotice)

        form.orders.nearby.gate = { XCTAssertNil(viewModel.nearbyVolunteersNotice, "旧出发点的卡还挂着") }
        viewModel.selectedStartPlace = place(id: "poi-2", latitude: 22.5, source: .manual)
        await viewModel.refreshNearbyVolunteers()

        XCTAssertEqual(form.orders.callCount("nearbyVolunteers(latitude:longitude:)"), 2)
    }

    /// 当前定位只是挪远了：等结果回来再换卡；查失败就撤掉。
    func testMovingFarKeepsTheCardUntilTheNewAnswerArrives() async {
        let form = makeForm()
        let viewModel = form.viewModel
        viewModel.selectedStartPlace = nil
        viewModel.currentResolvedPlace = place(id: "device-current", latitude: 31.2304, source: .deviceLocation)
        form.orders.nearby.results = [.success(response(has: false, hint: hint))]
        form.orders.nearby.result = .failure(APIError.networkError(URLError(.notConnectedToInternet)))
        await viewModel.refreshNearbyVolunteers()

        form.orders.nearby.gate = { XCTAssertNotNil(viewModel.nearbyVolunteersNotice, "同一出发点重查时卡不该闪掉") }
        viewModel.currentResolvedPlace = place(id: "device-current", latitude: 31.2504, source: .deviceLocation)
        await viewModel.refreshNearbyVolunteers()

        XCTAssertEqual(form.orders.callCount("nearbyVolunteers(latitude:longitude:)"), 2)
        XCTAssertNil(viewModel.nearbyVolunteersNotice)
    }

    /// 旧出发点的结果晚到，不许盖掉新出发点的结论。
    func testStaleResponseForThePreviousStartPlaceIsIgnored() async {
        let form = makeForm()
        // 第一次调用被挂住时换地点、查完第二次（有人），再放行第一次（没人）。
        let viewModel = form.viewModel
        let orders = form.orders
        let newPlace = place(id: "poi-2", latitude: 22.5, source: .manual)
        let noVolunteers = response(has: false, hint: hint)
        let hasVolunteers = response(has: true, hint: nil)
        orders.nearby.gate = {
            orders.nearby.gate = nil
            orders.nearby.results = [.success(hasVolunteers)]
            viewModel.selectedStartPlace = newPlace
            await viewModel.refreshNearbyVolunteers()
            orders.nearby.results = [.success(noVolunteers)]
        }

        await viewModel.refreshNearbyVolunteers()

        XCTAssertEqual(orders.callCount("nearbyVolunteers(latitude:longitude:)"), 2)
        XCTAssertNil(viewModel.nearbyVolunteersNotice)
    }

    /// 定位还没回来时的演示坐标不能拿去查。
    func testDemoCoordinateIsNotQueriedOutsideMock() async {
        let form = makeForm(environment: .demoCloud)
        form.viewModel.selectedStartPlace = nil
        form.viewModel.currentResolvedPlace = place(id: "demo-current", latitude: 39.9, source: .demoDefault)

        XCTAssertFalse(form.appState.currentEnvironment.isMock, "前提：不是 Mock 环境")
        await form.viewModel.refreshNearbyVolunteers()

        XCTAssertEqual(form.orders.callCount("nearbyVolunteers(latitude:longitude:)"), 0)
        XCTAssertNil(form.viewModel.nearbyVolunteersNotice)
    }

    /// 添加页选回原来的默认（含「使用当前定位」）时默认 id 不变，约跑页靠选择次数跟上。
    func testPickingTheSameDefaultStartPlaceAgainStillCounts() {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: directory) }
        let store = FavoritePlaceStore(directory: directory)

        XCTAssertTrue(store.setDefaultPlace(nil))
        XCTAssertTrue(store.setDefaultPlace(nil))

        XCTAssertNil(store.defaultPlaceID)
        XCTAssertEqual(store.defaultPickCount, 2)
    }

    func testMockSwitchesBetweenSomeoneAndNoOne() {
        XCTAssertNil(NearbyVolunteersNotice(MockAPIClient.mockNearbyVolunteers(nil)))
        XCTAssertNotNil(NearbyVolunteersNotice(MockAPIClient.mockNearbyVolunteers("none")))
    }

    // MARK: - 夹具

    private func response(has: Bool, hint: String?) -> NearbyVolunteersResponse {
        NearbyVolunteersResponse(hasNearbyVolunteers: has, radiusKm: 20, hint: hint)
    }

    private func makeSpeechForm() throws -> (Form, SpeechService, NearbyVolunteersNotice) {
        let form = makeForm()
        let speech = SpeechService()
        speech.isCallActive = { false }
        form.viewModel.configureForTesting(speechService: speech, locationService: form.location, appState: form.appState)
        let notice = try XCTUnwrap(NearbyVolunteersNotice(response(has: false, hint: hint)))
        return (form, speech, notice)
    }

    private func place(id: String, latitude: Double, source: LocationSource) -> ResolvedPlace {
        ResolvedPlace(id: id, title: id, addressText: id, latitude: latitude, longitude: 121.4737, source: source)
    }

    /// 下单 view model 的 `appState` / `locationService` 是 `weak`：整套依赖由用例持有。
    private struct Form {
        let viewModel: BlindBookingViewModel
        let appState: AppState
        let location: LocationService
        let orders: FakeOrderService
    }

    private func makeForm(environment: APIEnvironment? = nil) -> Form {
        let orders = FakeOrderService()
        let persistence = AppStatePersistenceFactory.makeIsolatedTest()
        addTeardownBlock { persistence.reset() }
        // 环境写进持久化、不给 `currentEnvironment` 赋值：赋值会跑会话清理，清掉测试机上真实的常用地点。
        if let environment {
            persistence.set(environment.rawValue, forKey: AppConstants.UserDefaultsKeys.apiEnvironment)
        }
        let appState = AppState(orders: orders, persistence: persistence, tokenStore: InMemoryTokenStore())
        let location = LocationService()
        location.simulatePreciseLocationOffForTesting(false)
        let viewModel = BlindBookingViewModel()
        viewModel.configureForTesting(speechService: SpeechService(), locationService: location, appState: appState)
        viewModel.selectedStartPlace = place(id: "poi-1", latitude: 31.2304, source: .manual)
        return Form(viewModel: viewModel, appState: appState, location: location, orders: orders)
    }
}
