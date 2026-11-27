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

    /// 当前定位抖动几十米不重查；挪出 1 公里或换了地点才查。
    func testQueriesAgainOnlyWhenTheStartPointChanges() async {
        let form = makeForm()
        form.viewModel.selectedStartPlace = nil
        form.viewModel.currentResolvedPlace = place(id: "device-current", latitude: 31.2304, source: .deviceLocation)
        form.orders.nearby.result = .success(response(has: false, hint: hint))

        await form.viewModel.refreshNearbyVolunteers()
        form.viewModel.currentResolvedPlace = place(id: "amap-regeo", latitude: 31.2309, source: .deviceLocation)
        await form.viewModel.refreshNearbyVolunteers()
        XCTAssertEqual(form.orders.callCount("nearbyVolunteers(latitude:longitude:)"), 1, "约 55 米，算同一个出发点")

        form.viewModel.currentResolvedPlace = place(id: "device-current", latitude: 31.2504, source: .deviceLocation)
        await form.viewModel.refreshNearbyVolunteers()
        XCTAssertEqual(form.orders.callCount("nearbyVolunteers(latitude:longitude:)"), 2, "约 2.2 公里")

        form.viewModel.selectedStartPlace = place(id: "poi-2", latitude: 31.2504, source: .manual)
        await form.viewModel.refreshNearbyVolunteers()
        XCTAssertEqual(form.orders.callCount("nearbyVolunteers(latitude:longitude:)"), 3, "换成了选定的地点")
    }

    func testChangingTheStartPlaceDropsTheOldCard() async {
        let form = makeForm()
        form.orders.nearby.results = [.success(response(has: false, hint: hint))]
        form.orders.nearby.result = .failure(APIError.networkError(URLError(.notConnectedToInternet)))
        await form.viewModel.refreshNearbyVolunteers()
        XCTAssertNotNil(form.viewModel.nearbyVolunteersNotice)

        form.viewModel.selectedStartPlace = place(id: "poi-2", latitude: 22.5, source: .manual)
        await form.viewModel.refreshNearbyVolunteers()

        XCTAssertNil(form.viewModel.nearbyVolunteersNotice)
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

        await form.viewModel.refreshNearbyVolunteers()

        XCTAssertEqual(form.orders.callCount("nearbyVolunteers(latitude:longitude:)"), 0)
        XCTAssertNil(form.viewModel.nearbyVolunteersNotice)
    }

    func testMockSwitchesBetweenSomeoneAndNoOne() {
        XCTAssertNil(NearbyVolunteersNotice(MockAPIClient.mockNearbyVolunteers(nil)))
        XCTAssertNotNil(NearbyVolunteersNotice(MockAPIClient.mockNearbyVolunteers("none")))
    }

    // MARK: - 夹具

    private func response(has: Bool, hint: String?) -> NearbyVolunteersResponse {
        NearbyVolunteersResponse(hasNearbyVolunteers: has, radiusKm: 20, hint: hint)
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
        let appState = AppState(orders: orders, persistence: persistence, tokenStore: InMemoryTokenStore())
        if let environment { appState.currentEnvironment = environment }
        let location = LocationService()
        let viewModel = BlindBookingViewModel()
        viewModel.configureForTesting(speechService: SpeechService(), locationService: location, appState: appState)
        viewModel.selectedStartPlace = place(id: "poi-1", latitude: 31.2304, source: .manual)
        return Form(viewModel: viewModel, appState: appState, location: location, orders: orders)
    }
}
