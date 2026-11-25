import Foundation

// 消息历史（`GET /api/notifications/history`，后端 #1052 / #1053，iOS #1025）。
//
// 契约：Spring 分页，裸对象（没有 `ApiResponse` 信封），时间倒序。`body` 是发送时已经渲染好的那句，
// 直接显示，不自己按事件拼；不下发 `ttsText`。`eventType` 是开放枚举且可为 null，所以这里**不建枚举**：
// 客户端对它没有任何分支，认不认识都照常显示 `body`。

/// 历史里的一条。除 `id` 和 `body` 外都可缺 / 为 null（老式通知只记了正文）。
nonisolated struct NotificationHistoryItem: Codable, Sendable, Equatable, Identifiable {
    let id: Int64
    /// 开放枚举，不解释。留着只为诊断。
    let eventType: String?
    /// 发送时已经渲染好的正文。
    let body: String
    /// `LocalDateTime`（无时区，按 Asia/Shanghai），可能带小数秒。
    let sentAt: String?
    let orderId: Int64?
    /// `HIGH` / `NORMAL` 等，老式通知为 null。
    let priority: String?

    init(
        id: Int64,
        eventType: String? = nil,
        body: String,
        sentAt: String? = nil,
        orderId: Int64? = nil,
        priority: String? = nil
    ) {
        self.id = id
        self.eventType = eventType
        self.body = body
        self.sentAt = sentAt
        self.orderId = orderId
        self.priority = priority
    }

    private enum CodingKeys: String, CodingKey {
        case id, eventType, body, sentAt, orderId, priority
    }

    /// `id` 与 `body` 缺失就整条抛：没有正文的一行对读屏用户是一个空白焦点，不如让页面显示「加载失败」。
    /// 其余键用 `try?`：类型对不上不该拖垮整页历史（同 `WSNotificationEnvelope.orderId`）。
    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(Int64.self, forKey: .id)
        body = try container.decode(String.self, forKey: .body)
        eventType = (try? container.decodeIfPresent(String.self, forKey: .eventType)) ?? nil
        sentAt = (try? container.decodeIfPresent(String.self, forKey: .sentAt)) ?? nil
        orderId = (try? container.decodeIfPresent(Int64.self, forKey: .orderId)) ?? nil
        priority = (try? container.decodeIfPresent(String.self, forKey: .priority)) ?? nil
    }

    /// 高优先级：求助、到达、取消预警这类（后端 `priority = HIGH`，与 APNs 补发同一个判据）。
    /// 只认 `HIGH`；`NORMAL`、null、不认识的值一律按普通处理。
    var isHighPriority: Bool {
        priority?.uppercased() == "HIGH"
    }
}

/// 历史的一页。`content` 缺失就抛（同 `PagedOrderResponse` 的理由）：
/// 解成空列表会让一个畸形响应显示成「还没有消息」。
nonisolated struct NotificationHistoryPage: Codable, Sendable, Equatable {
    let content: [NotificationHistoryItem]
    let number: Int?
    let totalPages: Int?
    let totalElements: Int64?
    let last: Bool?

    init(
        content: [NotificationHistoryItem],
        number: Int? = nil,
        totalPages: Int? = nil,
        totalElements: Int64? = nil,
        last: Bool? = nil
    ) {
        self.content = content
        self.number = number
        self.totalPages = totalPages
        self.totalElements = totalElements
        self.last = last
    }

    /// 后面还有没有。优先信 `last`，缺失时用 `number` 与 `totalPages` 推，再缺就看这一页满不满。
    /// 宁可多问一次拿到空页，也不能把没读完的历史说成「到底了」。
    func hasMore(requestedSize: Int) -> Bool {
        if let last { return !last }
        if let number, let totalPages { return number + 1 < totalPages }
        return content.count >= requestedSize
    }
}
