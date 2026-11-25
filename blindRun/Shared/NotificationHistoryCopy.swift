import Foundation

/// 消息历史页的文案与时间口径（#1025）。两端共用。
enum NotificationHistoryCopy {
    // MARK: 入口与标题

    /// 「我的」页的入口名与页面标题，是同一个常量。
    static let title = "消息"
    static let settingsHint = "查看最近收到的通知，错过的播报可以在这里再看一遍"
    /// 订单页「···」里的那一项与订单消息页标题。
    static let orderTitle = "这一单的消息"
    static let orderEntryHint = "查看这一单收到过的通知"
    static let close = "完成"

    // MARK: 状态

    static let loading = "正在读取消息"
    static let failed = "没有读到消息，检查网络后再试一次"
    static let retry = "重试"
    /// 保留期是后端定的（`app.notification.retention-days`，90 天）；写出来是为了让人知道更早的查不到。
    static let empty = "最近 90 天没有收到消息。"
    static let orderEmpty = "这一单还没有消息。"
    static let loadMore = "查看更早的消息"
    static let loadingMore = "正在读取更早的消息"
    static let loadMoreFailed = "没有读到更早的消息，检查网络后再试一次"
    static let reachedEnd = "已经到底了，只保留最近 90 天的消息。"
    static let orderReachedEnd = "这一单的消息就这些了。"

    static func emptyText(forOrder: Bool) -> String { forOrder ? orderEmpty : empty }
    static func endText(forOrder: Bool) -> String { forOrder ? orderReachedEnd : reachedEnd }
    static func loadedMore(_ count: Int) -> String {
        count > 0 ? "已加载 \(count) 条更早的消息" : "没有更早的消息了"
    }

    // MARK: 一行

    /// 高优先级的文字标记。颜色不是唯一区分（读屏和色弱用户都靠这个字）。
    static let highPriorityTag = "重要"

    /// 读屏一行：先正文，再时间，高优先级最后加一句。
    static func rowAccessibilityLabel(_ item: NotificationHistoryItem, now: Date = Date()) -> String {
        var parts = [item.body.trimmingCharacters(in: .whitespacesAndNewlines)]
        if let time = NotificationHistoryTime.spoken(sentAt: item.sentAt, now: now) { parts.append(time) }
        if item.isHighPriority { parts.append("\(highPriorityTag)消息") }
        return parts.joined(separator: "。")
    }
}

/// 一条通知的发送时间怎么写、怎么读。
///
/// `sentAt` 是无时区的北京时间（`String.backendTimestamp` 已按 Asia/Shanghai 解析）。
/// 「今天 / 昨天」也按北京时间的日历判：设备在别的时区时，用本地日历会把半夜的消息说成另一天。
enum NotificationHistoryTime {
    /// 屏幕上的写法：「今天 15:20」「昨天 21:00」「11月23日 09:05」，跨年带年份。
    static func display(sentAt: String?, now: Date = Date()) -> String? {
        guard let parts = Parts(sentAt: sentAt, now: now) else { return nil }
        let clock = String(format: "%02d:%02d", parts.hour, parts.minute)
        return "\(parts.dayWord) \(clock)"
    }

    /// 读屏的写法：「今天下午 3 点 20 分」「昨天晚上 9 点整」。
    ///
    /// 不用「15:20」：读屏会念成「十五冒号二十」，而人说话不这么说。
    static func spoken(sentAt: String?, now: Date = Date()) -> String? {
        guard let parts = Parts(sentAt: sentAt, now: now) else { return nil }
        let separator = parts.isRelativeDay ? "" : " "
        return "\(parts.dayWord)\(separator)\(period(hour: parts.hour)) \(hour12(parts.hour)) 点\(minuteWord(parts.minute))"
    }

    // MARK: 内部

    private struct Parts {
        let dayWord: String
        let isRelativeDay: Bool
        let hour: Int
        let minute: Int

        init?(sentAt: String?, now: Date) {
            guard let sentAt, let date = sentAt.backendTimestamp else { return nil }
            let calendar = Calendar.aidRunBackend
            let components = calendar.dateComponents([.year, .month, .day, .hour, .minute], from: date)
            guard let hour = components.hour, let minute = components.minute,
                  let month = components.month, let day = components.day else { return nil }
            self.hour = hour
            self.minute = minute
            if calendar.isDate(date, inSameDayAs: now) {
                dayWord = "今天"
                isRelativeDay = true
            } else if let yesterday = calendar.date(byAdding: .day, value: -1, to: now),
                      calendar.isDate(date, inSameDayAs: yesterday) {
                dayWord = "昨天"
                isRelativeDay = true
            } else if components.year != calendar.component(.year, from: now), let year = components.year {
                dayWord = "\(year)年\(month)月\(day)日"
                isRelativeDay = false
            } else {
                dayWord = "\(month)月\(day)日"
                isRelativeDay = false
            }
        }
    }

    private static func period(hour: Int) -> String {
        switch hour {
        case 0..<6: return "凌晨"
        case 6..<12: return "上午"
        case 12: return "中午"
        case 13..<18: return "下午"
        default: return "晚上"
        }
    }

    /// 12 小时制的钟点：0 点读「12」前面有「凌晨」，13–23 点减 12。
    private static func hour12(_ hour: Int) -> Int {
        switch hour {
        case 0: return 12
        case 1...12: return hour
        default: return hour - 12
        }
    }

    private static func minuteWord(_ minute: Int) -> String {
        minute == 0 ? "整" : " \(minute) 分"
    }
}
