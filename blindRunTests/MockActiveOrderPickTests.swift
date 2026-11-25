import XCTest
@testable import blindRun

/// Mock 的 `GET /api/orders/active` 在多张未走完的单里怎么挑（#938）。
/// ⚠️ 本文件在仓库里只编译过；单测只能真机跑（高德没有 arm64-sim slice）。
final class MockActiveOrderPickTests: XCTestCase {

    private func order(_ id: Int, _ status: String, planned: String, created: String) throws -> OrderDetailResponse {
        let json = "{\"orderId\":\(id),\"status\":\"\(status)\",\"plannedStart\":\"\(planned)\",\"createdAt\":\"\(created)\"}"
        return try JSONDecoder().decode(OrderDetailResponse.self, from: Data(json.utf8))
    }

    private func pickedId(_ orders: [OrderDetailResponse]) -> Int64? {
        let mock = MockAPIClient()
        mock.orders = orders
        return mock.handleGetActiveOrder().data?.orderId
    }

    /// 后创建但开跑更早的那张要被选中；按 `createdAt` 最新取单会选到 1。
    func testEarliestPlannedStartWinsOverNewestCreated() throws {
        let later = try order(1, "SCHEDULED_CONFIRMED", planned: "2030-01-02T07:00:00", created: "2026-11-26T10:00:00")
        let sooner = try order(2, "SCHEDULED_CONFIRMED", planned: "2030-01-01T07:00:00", created: "2026-11-26T09:00:00")
        XCTAssertEqual(pickedId([later, sooner]), 2)
        XCTAssertEqual(pickedId([sooner, later]), 2)
    }

    /// 已经在跑的排最前，哪怕另一张预约时间更早。
    func testRunningOrderComesFirst() throws {
        let running = try order(1, "IN_PROGRESS", planned: "2030-01-05T07:00:00", created: "2026-11-26T09:00:00")
        let earlier = try order(2, "SCHEDULED_CONFIRMED", planned: "2030-01-01T07:00:00", created: "2026-11-26T10:00:00")
        XCTAssertEqual(pickedId([earlier, running]), 1)
    }
}
