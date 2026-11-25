//
//  NotificationHistoryMockTests.swift
//  blindRunTests
//
//  消息历史（#1025）的 Mock 后端：倒序、按订单过滤、分页、400、未登录。
//

import XCTest
@testable import blindRun

@MainActor
final class NotificationHistoryMockTests: XCTestCase {

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
}
