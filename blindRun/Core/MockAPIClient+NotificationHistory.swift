import Foundation

extension MockAPIClient {
    /// 后端每页上限 50，超过回 400（契约 `/api/notifications/history`）。
    static let mockNotificationHistoryMaxPageSize = 50

    /// `GET /api/notifications/*` 的分发：路由函数已超长，新增一条读接口不许再让它变大，所以收在这里。
    func handleGetNotifications(path: String, query: [String: String]?) throws -> Any {
        switch path {
        case "/api/notifications/history": return try handleGetNotificationHistory(query: query)
        case "/api/notifications/since": return try handleGetMissedNotifications(after: query?["after"])
        default: throw APIError.invalidURL
        }
    }

    /// `GET /api/notifications/history`：只返回当前登录人自己的通知，倒序，Spring 分页。
    /// Mock 里只有一个登录人，所以语料不分人；`orderId` 过滤照契约做。
    func handleGetNotificationHistory(query: [String: String]?) throws -> NotificationHistoryPage {
        guard mockToken != nil, !isAccountDeleted else { throw APIError.unauthorized }
        let page = Int(query?["page"] ?? "") ?? 0
        let size = Int(query?["size"] ?? "") ?? 20
        guard page >= 0, size >= 1, size <= Self.mockNotificationHistoryMaxPageSize else {
            throw APIError.serverError(ErrorResponse(code: "VALIDATION_ERROR", message: "分页参数不合法"))
        }
        var rows = notificationHistory
        if let raw = query?["orderId"] {
            guard let orderId = Int64(raw), orderId >= 1 else {
                throw APIError.serverError(ErrorResponse(code: "VALIDATION_ERROR", message: "orderId 不合法"))
            }
            rows = rows.filter { $0.orderId == orderId }
        }
        // 时间倒序；同一时刻按 id 倒序，翻页顺序才稳定。
        rows.sort { lhs, rhs in
            let l = lhs.sentAt ?? "", r = rhs.sentAt ?? ""
            return l == r ? lhs.id > rhs.id : l > r
        }
        let total = rows.count
        let start = min(page * size, total)
        let slice = Array(rows[start..<min(start + size, total)])
        let totalPages = total == 0 ? 0 : (total + size - 1) / size
        return NotificationHistoryPage(
            content: slice,
            number: page,
            totalPages: totalPages,
            totalElements: Int64(total),
            last: page + 1 >= totalPages
        )
    }

    /// 铺几条样子各异的：认识的事件、不认识的事件、`eventType` 与 `priority` 为 null 的老式行、没挂订单的行。
    /// 时间相对此刻，免得开发期永远看到「很久以前」。
    func seedNotificationHistory() {
        let now = Date()
        func stamp(_ secondsAgo: TimeInterval) -> String {
            DateFormatter.aidRunBackendLocalDateTime.string(from: now.addingTimeInterval(-secondsAgo))
        }
        let orderId = orders.first?.orderId
        notificationHistory = [
            NotificationHistoryItem(
                id: 9005, eventType: "DRIVER_ARRIVED", body: "陪跑员已到达集合点，请到起点附近汇合。",
                sentAt: stamp(20 * 60), orderId: orderId, priority: "HIGH"
            ),
            NotificationHistoryItem(
                id: 9004, eventType: "ORDER_ACCEPTED", body: "已有陪跑员接单，正在安排见面细节。",
                sentAt: stamp(3 * 3600), orderId: orderId, priority: "HIGH"
            ),
            NotificationHistoryItem(
                id: 9003, eventType: "SOME_FUTURE_EVENT", body: "这是一条客户端还不认识的事件，照常显示正文。",
                sentAt: stamp(26 * 3600), orderId: orderId, priority: "NORMAL"
            ),
            NotificationHistoryItem(
                id: 9002, eventType: nil, body: "只记了正文的老式通知。",
                sentAt: stamp(3 * 24 * 3600), orderId: nil, priority: nil
            ),
            NotificationHistoryItem(
                id: 9001, eventType: "SUPPORT_TICKET_REPLIED", body: "客服回复了你提交的反馈。",
                sentAt: stamp(10 * 24 * 3600), orderId: nil, priority: "NORMAL"
            )
        ]
    }
}
