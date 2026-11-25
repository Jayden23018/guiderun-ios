//
//  NotificationHistoryService.swift
//  blindRun
//
//  领域 service 层的一片：消息历史。范例是 `TrainingService.swift`。
//

import Foundation

// MARK: - Endpoints

/// 消息历史片用到的端点。**完整字面量路径**，不许拼接（`scripts/validate-spec-coverage.mjs` 只认字符串字面量）。
///
/// 🚩 不并进 `AuthEndpoint.missedNotifications`：那条是断线补读（24 小时、50 条、正序、带 `ttsText`），
/// 这条是历史页（90 天、分页、倒序、不带 `ttsText`），契约明说「不要拿 `/since` 当历史页」。
enum NotificationHistoryEndpoint {
    case history

    var request: EndpointRequest {
        switch self {
        case .history:
            return EndpointRequest(.get, "/api/notifications/history")
        }
    }
}

// MARK: - Protocol

/// 消息历史对外的全部能力。错误一律 `throws`，**这一层不吞**：谁渲染谁 catch，
/// 吞在这里的失败在盲人端表现为「点了没反应」。
protocol NotificationHistoryServing: Sendable {
    /// 一页历史（时间倒序）。`orderId` 为 nil = 全部，非 nil = 只看这一单。`page` 从 0 起。
    /// 返回**一页**，翻页与去重由调用方负责。
    func history(orderId: Int64?, page: Int, size: Int) async throws -> NotificationHistoryPage
}

// MARK: - Implementation

/// 唯一的生产实现。只做两件事：选端点、转参数。
struct NotificationHistoryService: NotificationHistoryServing {
    let transport: any APIClientProtocol

    init(transport: any APIClientProtocol) {
        self.transport = transport
    }

    func history(orderId: Int64?, page: Int, size: Int) async throws -> NotificationHistoryPage {
        var query = ["page": String(page), "size": String(size)]
        if let orderId { query["orderId"] = String(orderId) }
        return try await transport.send(NotificationHistoryEndpoint.history.request, query: query)
    }
}
