//
//  NotificationHistoryTests.swift
//  blindRunTests
//
//  消息历史页（#1025）：契约解码、端点映射、时间口径、读屏文案、Mock 后端、view model。
//  契约来源：后端 `docs/api_spec.yaml` 的 `/api/notifications/history` 与 `NotificationHistoryItem`。
//

import XCTest
@testable import blindRun

@MainActor
final class NotificationHistoryTests: XCTestCase {

    // MARK: - 解码

    /// 契约里的 Spring 分页：带 `pageable` / `sort` 这些客户端用不到的键，裸对象、没有信封。
    func testDecodesSpringPageWithoutEnvelope() throws {
        let json = """
        {"content":[
          {"id":7,"eventType":"ORDER_ACCEPTED","body":"已有陪跑员接单","sentAt":"2026-11-25T15:20:00","orderId":42,"priority":"HIGH"}
        ],"pageable":{"pageNumber":0,"pageSize":20},"sort":{"sorted":true},
        "totalElements":1,"totalPages":1,"number":0,"size":20,"first":true,"last":true,"empty":false,"numberOfElements":1}
        """
        let page = try APIPayloadDecoder.decodePayload(
            NotificationHistoryPage.self, from: Data(json.utf8), decoder: JSONDecoder()
        )
        XCTAssertEqual(page.content.count, 1)
        XCTAssertEqual(page.content[0].orderId, 42)
        XCTAssertTrue(page.content[0].isHighPriority)
        XCTAssertEqual(page.last, true)
    }

    /// 验收 3：不认识的 `eventType`、null 的 `eventType` / `priority`、没挂订单的行，都照常解出来。
    func testDecodesUnknownAndNullFields() throws {
        let json = """
        {"content":[
          {"id":1,"eventType":"SOME_FUTURE_EVENT","body":"新事件","sentAt":"2026-11-25T15:20:00.123456","orderId":null,"priority":"URGENT_V2"},
          {"id":2,"eventType":null,"body":"老式通知","sentAt":"2026-11-25T15:20","orderId":null,"priority":null},
          {"id":3,"body":"连键都没有"}
        ],"number":0,"totalPages":1,"last":true}
        """
        let page = try JSONDecoder().decode(NotificationHistoryPage.self, from: Data(json.utf8))
        XCTAssertEqual(page.content.map(\.id), [1, 2, 3])
        XCTAssertEqual(page.content[0].eventType, "SOME_FUTURE_EVENT")
        XCTAssertFalse(page.content[0].isHighPriority, "不认识的优先级按普通处理")
        XCTAssertNil(page.content[1].eventType)
        XCTAssertNil(page.content[2].sentAt)
        XCTAssertEqual(page.content[2].body, "连键都没有")
    }

    func testItemTypeMismatchInOptionalKeyDoesNotDropTheRow() throws {
        let json = #"{"content":[{"id":1,"body":"正文","orderId":"不是数字","priority":5}]}"#
        let page = try JSONDecoder().decode(NotificationHistoryPage.self, from: Data(json.utf8))
        XCTAssertEqual(page.content.count, 1)
        XCTAssertNil(page.content[0].orderId)
        XCTAssertNil(page.content[0].priority)
    }

    /// 缺 `content` / 缺 `body` 必须抛：解成空列表会把畸形响应说成「没有收到消息」。
    func testMissingContentOrBodyThrows() {
        XCTAssertThrowsError(try JSONDecoder().decode(NotificationHistoryPage.self, from: Data(#"{"number":0}"#.utf8)))
        XCTAssertThrowsError(try JSONDecoder().decode(
            NotificationHistoryPage.self, from: Data(#"{"content":[{"id":1}]}"#.utf8)
        ))
    }

    func testHasMorePrefersLastThenPageCountThenFullPage() {
        XCTAssertTrue(NotificationHistoryPage(content: [], last: false).hasMore(requestedSize: 20))
        XCTAssertFalse(NotificationHistoryPage(content: [], last: true).hasMore(requestedSize: 20))
        XCTAssertTrue(NotificationHistoryPage(content: [], number: 0, totalPages: 2).hasMore(requestedSize: 20))
        XCTAssertFalse(NotificationHistoryPage(content: [], number: 1, totalPages: 2).hasMore(requestedSize: 20))
        // 什么分页信息都没有：满页当还有，不满页当到底。
        let full = (1...2).map { NotificationHistoryItem(id: Int64($0), body: "x") }
        XCTAssertTrue(NotificationHistoryPage(content: full).hasMore(requestedSize: 2))
        XCTAssertFalse(NotificationHistoryPage(content: full).hasMore(requestedSize: 3))
    }

    // MARK: - 端点映射

    func testHistoryRequestCarriesPagingAndOrderFilter() async throws {
        let transport = RecordingTransport()
        transport.nextResponse = NotificationHistoryPage(content: [])
        _ = try await NotificationHistoryService(transport: transport).history(orderId: 42, page: 2, size: 20)

        let sent = try XCTUnwrap(transport.requests.first)
        XCTAssertEqual(sent.method, .get)
        XCTAssertEqual(sent.path, "/api/notifications/history", "不是 /since：那条是断线补读")
        XCTAssertTrue(sent.requiresAuth)
        XCTAssertEqual(sent.query, ["page": "2", "size": "20", "orderId": "42"])
    }

    func testHistoryWithoutOrderIdOmitsTheFilterKey() async throws {
        let transport = RecordingTransport()
        transport.nextResponse = NotificationHistoryPage(content: [])
        _ = try await NotificationHistoryService(transport: transport).history(orderId: nil, page: 0, size: 20)
        XCTAssertNil(transport.requests.first?.query?["orderId"], "不传 = 全部；传空串后端会 400")
    }

    // MARK: - 时间口径（北京时间；now 固定为 2026-11-25 16:00）

    private var now: Date { "2026-11-25T16:00:00".backendTimestamp! }

    func testSpokenTimeReadsLikeSpeech() {
        XCTAssertEqual(NotificationHistoryTime.spoken(sentAt: "2026-11-25T15:20:00", now: now), "今天下午 3 点 20 分")
        XCTAssertEqual(NotificationHistoryTime.spoken(sentAt: "2026-11-24T21:00:00", now: now), "昨天晚上 9 点整")
        XCTAssertEqual(NotificationHistoryTime.spoken(sentAt: "2026-11-23T09:05:00", now: now), "11月23日 上午 9 点 5 分")
        XCTAssertEqual(NotificationHistoryTime.spoken(sentAt: "2026-11-25T00:30:00", now: now), "今天凌晨 12 点 30 分")
        XCTAssertEqual(NotificationHistoryTime.spoken(sentAt: "2026-11-25T12:00:00", now: now), "今天中午 12 点整")
        XCTAssertEqual(NotificationHistoryTime.spoken(sentAt: "2025-12-31T23:59:00", now: now), "2025年12月31日 晚上 11 点 59 分")
    }

    func testSpokenTimeAcceptsFractionalSecondsAndMissingSeconds() {
        XCTAssertEqual(NotificationHistoryTime.spoken(sentAt: "2026-11-25T15:20:00.644571", now: now), "今天下午 3 点 20 分")
        XCTAssertEqual(NotificationHistoryTime.spoken(sentAt: "2026-11-25T15:20", now: now), "今天下午 3 点 20 分")
    }

    func testUnparseableOrMissingTimeIsOmittedNotInvented() {
        XCTAssertNil(NotificationHistoryTime.spoken(sentAt: nil, now: now))
        XCTAssertNil(NotificationHistoryTime.spoken(sentAt: "不是时间", now: now))
        XCTAssertNil(NotificationHistoryTime.display(sentAt: "", now: now))
    }

    func testDisplayTimeIsShortAndRelative() {
        XCTAssertEqual(NotificationHistoryTime.display(sentAt: "2026-11-25T15:20:00", now: now), "今天 15:20")
        XCTAssertEqual(NotificationHistoryTime.display(sentAt: "2026-11-24T09:05:00", now: now), "昨天 09:05")
        XCTAssertEqual(NotificationHistoryTime.display(sentAt: "2026-11-01T09:05:00", now: now), "11月1日 09:05")
    }

    // MARK: - 读屏一行

    /// 验收 4：先正文，再时间，高优先级最后一句，且有文字不只靠颜色。
    func testRowLabelReadsBodyThenTimeThenPriority() {
        let high = NotificationHistoryItem(id: 1, eventType: "DRIVER_ARRIVED", body: "陪跑员已到达", sentAt: "2026-11-25T15:20:00", priority: "HIGH")
        XCTAssertEqual(
            NotificationHistoryCopy.rowAccessibilityLabel(high, now: now),
            "陪跑员已到达。今天下午 3 点 20 分。重要消息"
        )
        let normal = NotificationHistoryItem(id: 2, body: "已接单", sentAt: "2026-11-25T15:20:00", priority: "NORMAL")
        XCTAssertEqual(NotificationHistoryCopy.rowAccessibilityLabel(normal, now: now), "已接单。今天下午 3 点 20 分")
        let bare = NotificationHistoryItem(id: 3, body: "只有正文")
        XCTAssertEqual(NotificationHistoryCopy.rowAccessibilityLabel(bare, now: now), "只有正文")
    }

    // MARK: - Mock 后端

    private func makeMock(_ items: [NotificationHistoryItem]) -> MockAPIClient {
        let mock = MockAPIClient()
        mock.mockToken = "test-token"
        mock.notificationHistory = items
        return mock
    }

    func testMockHistoryIsNewestFirstAndFiltersByOrder() async throws {
        let mock = makeMock([
            NotificationHistoryItem(id: 1, body: "旧", sentAt: "2026-11-20T10:00:00", orderId: 5),
            NotificationHistoryItem(id: 2, body: "新", sentAt: "2026-11-25T10:00:00", orderId: 5),
            NotificationHistoryItem(id: 3, body: "别的单", sentAt: "2026-11-24T10:00:00", orderId: 6)
        ])
        let all = try await NotificationHistoryService(transport: mock).history(orderId: nil, page: 0, size: 20)
        XCTAssertEqual(all.content.map(\.id), [2, 3, 1])
        let one = try await NotificationHistoryService(transport: mock).history(orderId: 5, page: 0, size: 20)
        XCTAssertEqual(one.content.map(\.id), [2, 1])
    }

    func testMockHistoryPagesAndReportsLast() async throws {
        let items = (1...5).map {
            NotificationHistoryItem(id: Int64($0), body: "第 \($0) 条", sentAt: "2026-11-25T10:0\($0):00")
        }
        let service = NotificationHistoryService(transport: makeMock(items))
        let first = try await service.history(orderId: nil, page: 0, size: 2)
        XCTAssertEqual(first.content.map(\.id), [5, 4])
        XCTAssertEqual(first.last, false)
        XCTAssertEqual(first.totalPages, 3)
        let third = try await service.history(orderId: nil, page: 2, size: 2)
        XCTAssertEqual(third.content.map(\.id), [1])
        XCTAssertEqual(third.last, true)
        let beyond = try await service.history(orderId: nil, page: 9, size: 2)
        XCTAssertTrue(beyond.content.isEmpty)
    }

    func testMockHistoryRejectsOversizedPageLikeTheBackend() async {
        let service = NotificationHistoryService(transport: makeMock([]))
        do {
            _ = try await service.history(orderId: nil, page: 0, size: 51)
            XCTFail("size 超过 50 后端回 400")
        } catch {
            XCTAssertNotNil(error as? APIError)
        }
    }

    func testMockHistoryNeedsLogin() async {
        let mock = MockAPIClient()
        mock.mockToken = nil
        do {
            _ = try await NotificationHistoryService(transport: mock).history(orderId: nil, page: 0, size: 20)
            XCTFail("未登录应 401")
        } catch {
            guard case .unauthorized? = error as? APIError else { return XCTFail("应是 unauthorized：\(error)") }
        }
    }

    // MARK: - View model

    private func item(_ id: Int64) -> NotificationHistoryItem {
        NotificationHistoryItem(id: id, body: "消息 \(id)", sentAt: "2026-11-25T10:00:00")
    }

    private func page(_ ids: [Int64], last: Bool) -> NotificationHistoryPage {
        NotificationHistoryPage(content: ids.map(item), last: last)
    }

    func testFirstLoadShowsRowsAndAsksForPageZeroWithOrderFilter() async {
        let service = FakeNotificationHistoryService([.success(page([3, 2, 1], last: true))])
        let viewModel = NotificationHistoryViewModel(orderId: 42)
        await viewModel.load(service: service)

        XCTAssertEqual(service.calls, [.init(orderId: 42, page: 0, size: NotificationHistoryViewModel.pageSize)])
        guard case .loaded(let listing) = viewModel.phase else { return XCTFail("应已加载：\(viewModel.phase)") }
        XCTAssertEqual(listing.items.map(\.id), [3, 2, 1])
        XCTAssertNil(listing.nextPage, "后端说是最后一页就到底了")
    }

    /// 验收 5：空列表是 `.loaded` 且无行，失败是 `.failed`，两者不混。
    func testEmptyIsLoadedButFailureIsFailedNotEmpty() async {
        let empty = NotificationHistoryViewModel()
        await empty.load(service: FakeNotificationHistoryService([.success(page([], last: true))]))
        guard case .loaded(let listing) = empty.phase else { return XCTFail("空列表应是 loaded") }
        XCTAssertTrue(listing.items.isEmpty)

        let failing = NotificationHistoryViewModel()
        await failing.load(service: FakeNotificationHistoryService([.failure(APIError.unknown(statusCode: 500))]))
        guard case .failed(let message) = failing.phase else { return XCTFail("失败不能落成空列表：\(failing.phase)") }
        XCTAssertEqual(message, NotificationHistoryCopy.failed)
    }

    func testRefreshFailureKeepsRowsAlreadyShown() async {
        let service = FakeNotificationHistoryService([
            .success(page([2, 1], last: true)),
            .failure(APIError.unknown(statusCode: 500))
        ])
        let viewModel = NotificationHistoryViewModel()
        await viewModel.load(service: service)
        await viewModel.load(service: service)
        guard case .loaded(let listing) = viewModel.phase else { return XCTFail("刷新失败不该丢掉列表：\(viewModel.phase)") }
        XCTAssertEqual(listing.items.map(\.id), [2, 1])
    }

    func testLoadMoreAppendsAndDedupsByIdThenReachesEnd() async {
        let service = FakeNotificationHistoryService([
            .success(page([5, 4], last: false)),
            // 翻页期间有新通知把后面的行挤了一格：4 在第二页又出现一次。
            .success(page([4, 3], last: true))
        ])
        let viewModel = NotificationHistoryViewModel()
        await viewModel.load(service: service)
        let added = await viewModel.loadMore(service: service)

        XCTAssertEqual(added, 1, "4 已经有了，只新增 3")
        XCTAssertEqual(service.calls.map(\.page), [0, 1])
        guard case .loaded(let listing) = viewModel.phase else { return XCTFail() }
        XCTAssertEqual(listing.items.map(\.id), [5, 4, 3])
        XCTAssertNil(listing.nextPage)
        let again = await viewModel.loadMore(service: service)
        XCTAssertNil(again, "到底之后不再发请求")
        XCTAssertEqual(service.calls.count, 2)
    }

    /// 翻页失败不是「到底了」：停在可重试，且已经显示的行还在。
    func testLoadMoreFailureStaysRetryableAndKeepsRows() async {
        let service = FakeNotificationHistoryService([
            .success(page([2, 1], last: false)),
            .failure(APIError.unknown(statusCode: 500)),
            .success(page([0], last: true))
        ])
        let viewModel = NotificationHistoryViewModel()
        await viewModel.load(service: service)
        let failed = await viewModel.loadMore(service: service)
        XCTAssertNil(failed)
        guard case .loaded(let afterFailure) = viewModel.phase else { return XCTFail() }
        XCTAssertEqual(afterFailure.moreState, .failed)
        XCTAssertEqual(afterFailure.nextPage, 1, "失败后仍然要重试同一页")
        XCTAssertEqual(afterFailure.items.map(\.id), [2, 1])

        let retried = await viewModel.loadMore(service: service)
        XCTAssertEqual(retried, 1)
        XCTAssertEqual(service.calls.map(\.page), [0, 1, 1])
    }

    /// 翻页在飞时刷新失败：列表没换，翻页结果照常接上，「更多」不会卡在「正在读取」。
    func testLoadMoreStillAppliesWhenRefreshFailsMeanwhile() async {
        let service = FakeNotificationHistoryService([
            .success(page([2, 1], last: false)),
            .success(page([0], last: true)),
            .failure(APIError.unknown(statusCode: 500))
        ])
        let viewModel = NotificationHistoryViewModel()
        await viewModel.load(service: service)

        let release = AsyncGate()
        service.gate = { await release.wait() }
        let pending = Task { await viewModel.loadMore(service: service) }
        while service.calls.count < 2 { await Task.yield() }
        service.gate = nil
        await viewModel.load(service: service)   // 刷新失败，列表保留
        await release.open()
        _ = await pending.value

        guard case .loaded(let listing) = viewModel.phase else { return XCTFail() }
        XCTAssertEqual(listing.items.map(\.id), [2, 1, 0])
        XCTAssertEqual(listing.moreState, .idle)
    }

    /// 翻页请求在飞时用户下拉刷新：旧的第 2 页回来不许接到新的第 1 页后面。
    func testStaleLoadMoreResultIsDroppedAfterRefresh() async {
        let fresh = page([9, 8], last: true)
        let service = FakeNotificationHistoryService([
            .success(page([2, 1], last: false)),   // 首次加载
            .success(page([0], last: true)),       // 被丢弃的旧第 2 页
            .success(fresh)                        // 刷新
        ])
        let viewModel = NotificationHistoryViewModel()
        await viewModel.load(service: service)

        let release = AsyncGate()
        service.gate = { await release.wait() }
        let pending = Task { await viewModel.loadMore(service: service) }
        // 等翻页请求真的发出去并停在 gate 里（记调用在等 gate 之前），否则下面的刷新可能先于它。
        while service.calls.count < 2 { await Task.yield() }
        service.gate = nil
        await viewModel.load(service: service)   // 刷新先落地
        await release.open()
        _ = await pending.value

        guard case .loaded(let listing) = viewModel.phase else { return XCTFail() }
        XCTAssertEqual(listing.items.map(\.id), [9, 8], "旧页被丢弃，不污染刷新后的列表")
    }
}

/// 让一个请求停在半路，等测试放行。
private actor AsyncGate {
    private var isOpen = false
    private var waiters: [CheckedContinuation<Void, Never>] = []

    func wait() async {
        if isOpen { return }
        await withCheckedContinuation { waiters.append($0) }
    }

    func open() {
        isOpen = true
        waiters.forEach { $0.resume() }
        waiters.removeAll()
    }
}
