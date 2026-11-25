import Foundation

// MARK: - 订单为什么结束（后端 #1045 / #1047，iOS #1021）
//
// `OrderDetailResponse.closeReason` / `closedBy`。只在 `COMPLETED` / `CANCELLED` / `NO_VOLUNTEER` 有值，
// 2026-11-25 之前结束的订单为 null（没有回填）。两个字段同有同无。
// 陪跑员端的结束原因显示是另一张卡，复用这里的两个枚举。

/// 这一单为什么结束。**开放枚举**：不认识的值和 null 一样，按「原因不详」处理，不让整张订单解码失败。
nonisolated enum OrderCloseReason: String, Codable, Sendable, Equatable, UnknownFallbackDecodable {
    // COMPLETED
    case finishedBlindConfirmed = "FINISHED_BLIND_CONFIRMED"
    case finishedByVolunteer = "FINISHED_BY_VOLUNTEER"
    case finishedByVolunteerUnconfirmed = "FINISHED_BY_VOLUNTEER_UNCONFIRMED"
    case finishedByBlindVolunteerOffline = "FINISHED_BY_BLIND_VOLUNTEER_OFFLINE"
    case autoCompleted = "AUTO_COMPLETED"
    case csCompleted = "CS_COMPLETED"
    // CANCELLED
    case blindCancelled = "BLIND_CANCELLED"
    case blindCancelledAfterArrival = "BLIND_CANCELLED_AFTER_ARRIVAL"
    case blindNoShow = "BLIND_NO_SHOW"
    case matchTimeout = "MATCH_TIMEOUT"
    case rematchLimitReached = "REMATCH_LIMIT_REACHED"
    case emergencyUnresolved = "EMERGENCY_UNRESOLVED"
    case csCancelled = "CS_CANCELLED"
    /// `CANCELLED` 与 `NO_VOLUNTEER` 都会出现这个值，说法不同，所以文案要连状态一起看。
    case startTimeLongPassed = "START_TIME_LONG_PASSED"
    case systemForceClosed = "SYSTEM_FORCE_CLOSED"
    case accountSuspended = "ACCOUNT_SUSPENDED"
    // NO_VOLUNTEER
    case dispatchWindowExpired = "DISPATCH_WINDOW_EXPIRED"
    case introCallWindowTooShort = "INTRO_CALL_WINDOW_TOO_SHORT"
    case introCallFailedWindowTooShort = "INTRO_CALL_FAILED_WINDOW_TOO_SHORT"
    case introCallRoundsExhausted = "INTRO_CALL_ROUNDS_EXHAUSTED"
    case unknown = "UNKNOWN"
}

/// 这一单是谁结束的。开放枚举，规则同 `OrderCloseReason`。
nonisolated enum OrderClosedBy: String, Codable, Sendable, Equatable, UnknownFallbackDecodable {
    case blind = "BLIND"
    case volunteer = "VOLUNTEER"
    case system = "SYSTEM"
    case cs = "CS"
    case unknown = "UNKNOWN"
}

/// 开放枚举字段的宽容解码：缺键、`null`、类型不对一律得 `nil`，认不出的字符串由枚举自己落到 `.unknown`。
/// 类型不对时不抛错：这两个字段只决定页面上多一句原因，不值得让整张订单空白（`AGENTS.md` 硬约束）。
@propertyWrapper
nonisolated struct LenientOpenEnum<Value: Codable & Sendable & Equatable>: Codable, Sendable, Equatable {
    var wrappedValue: Value?

    init(wrappedValue: Value?) {
        self.wrappedValue = wrappedValue
    }

    init(from decoder: Decoder) throws {
        wrappedValue = try? decoder.singleValueContainer().decode(Value.self)
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(wrappedValue)
    }
}

extension KeyedDecodingContainer {
    nonisolated func decode<Value>(_ type: LenientOpenEnum<Value>.Type, forKey key: Key) throws -> LenientOpenEnum<Value> {
        try decodeIfPresent(type, forKey: key) ?? LenientOpenEnum<Value>(wrappedValue: nil)
    }
}

// MARK: - 跑者端文案

/// 终态页上的两句话：先说发生了什么，再说现在可以做什么。给读屏听的，一句一个意思，不带英文状态名，不归咎任何一方。
///
/// 🚨 **「无声拒绝」**（`AGENTS.md` §5）：通话没成的几种原因不说「对方拒绝」，也不说轮次，只说「时间不够」「次数用完」。
/// 🚨 `SYSTEM_FORCE_CLOSED` 这一单实际可能跑完了，**不说「没跑成」**。
/// 🚨 不承诺 App 做不到的事：不说「已通知」「已处理」。
struct BlindCloseReasonCopy: Equatable {
    /// 发生了什么。
    let reason: String
    /// 现在可以做什么。
    let nextStep: String

    /// 读屏念的整段：原因在前，下一步在后。
    var spoken: String { "\(reason)\(nextStep)" }

    /// 联系客服的路径。`ACCOUNT_SUSPENDED` 与几个需要说理的值用。写的是页面上真有的入口名（`SupportTicketCopy.title`）。
    static let contactSupport = "可以到「我的」页，点「\(SupportTicketCopy.title)」。"
    private static let rebook = "需要的话，可以重新预约。"
    private static let goHome = "接下来可以返回首页。"

    /// 状态与原因对不上（例如已取消的单带了 `FINISHED_*`）按「原因不详」处理：宁可少说一句，也不对盲人说错一句。
    static func make(reason: OrderCloseReason?, status: RunOrderStatus) -> BlindCloseReasonCopy? {
        guard let reason else { return nil }
        switch status {
        case .completed:
            return completed(reason)
        case .cancelled:
            return cancelled(reason)
        case .noVolunteer:
            return noVolunteer(reason)
        case .pendingMatch, .pendingIntroCall, .scheduledConfirmed, .pendingAccept, .inProgress,
             .driverEnRoute, .driverArrived, .rematching, .unknown:
            return nil
        }
    }

    private static func completed(_ reason: OrderCloseReason) -> BlindCloseReasonCopy? {
        switch reason {
        case .finishedBlindConfirmed:
            return .init(reason: "陪跑员结束了这次陪跑，你已确认自己在安全的地方。",
                         nextStep: "可以给这次陪跑打个分，然后返回首页。")
        case .finishedByVolunteer:
            return .init(reason: "陪跑员结束了这次陪跑。",
                         nextStep: "可以给这次陪跑打个分，然后返回首页。")
        case .finishedByVolunteerUnconfirmed:
            return .init(reason: "陪跑员请求结束时，系统没有收到你的确认，这次陪跑已经结束。",
                         nextStep: "请确认自己现在在安全的地方，需要帮助就打电话求助。")
        case .finishedByBlindVolunteerOffline:
            return .init(reason: "陪跑员的手机一直没有位置信息，你结束了这次陪跑。",
                         nextStep: goHome)
        case .autoCompleted:
            return .init(reason: "已经过了计划结束的时间，系统自动结束了这次陪跑。",
                         nextStep: goHome)
        case .csCompleted:
            return .init(reason: "客服把这次陪跑记为已完成。",
                         nextStep: "有疑问的话，\(contactSupport)")
        case .blindCancelled, .blindCancelledAfterArrival, .blindNoShow, .matchTimeout, .rematchLimitReached,
             .emergencyUnresolved, .csCancelled, .startTimeLongPassed, .systemForceClosed, .accountSuspended,
             .dispatchWindowExpired, .introCallWindowTooShort, .introCallFailedWindowTooShort,
             .introCallRoundsExhausted, .unknown:
            return nil
        }
    }

    private static func cancelled(_ reason: OrderCloseReason) -> BlindCloseReasonCopy? {
        switch reason {
        case .blindCancelled:
            return .init(reason: "你取消了这次预约。", nextStep: rebook)
        case .blindCancelledAfterArrival:
            return .init(reason: "陪跑员到了集合点，等了一阵没有碰上面，你取消了这次预约。", nextStep: rebook)
        case .blindNoShow:
            return .init(reason: "陪跑员到了集合点，等了一阵没有碰上面，陪跑员结束了等待。", nextStep: rebook)
        case .matchTimeout:
            return .init(reason: "一直没有陪跑员接单，等待的次数用完了，预约已取消。",
                         nextStep: "可以重新预约，也可以换一个时间。")
        case .rematchLimitReached:
            return .init(reason: "陪跑员几次来不了，重新找人的次数用完了，预约已取消。", nextStep: rebook)
        case .startTimeLongPassed:
            return .init(reason: "约定的开跑时间已经过去很久，陪跑一直没有开始，系统取消了这次预约。", nextStep: rebook)
        default:
            return cancelledNeedingSupport(reason)
        }
    }

    /// 已取消里需要指路联系客服的几种。拆出来是为了不让上面那个 switch 的圈复杂度超线；
    /// 其余值（不属于已取消的）一律回 `nil`。
    private static func cancelledNeedingSupport(_ reason: OrderCloseReason) -> BlindCloseReasonCopy? {
        switch reason {
        case .emergencyUnresolved:
            return .init(reason: "这一单的求助还没有处理完，已过计划结束时间，系统结束了这一单。",
                         nextStep: "求助仍由客服跟进。\(contactSupport)")
        case .csCancelled:
            return .init(reason: "客服取消了这次预约。", nextStep: "有疑问的话，\(contactSupport)")
        case .systemForceClosed:
            // 不说「没跑成」：自动完成连续失败后的兜底终止，这一单实际可能已经跑完。
            return .init(reason: "系统结束了这一单。",
                         nextStep: "如果你已经跑完了，不用做什么。有疑问的话，\(contactSupport)")
        case .accountSuspended:
            return .init(reason: "你的账号已被平台停用，还没开始的预约已取消。", nextStep: "请联系客服了解详情。\(contactSupport)")
        default:
            return nil
        }
    }

    private static func noVolunteer(_ reason: OrderCloseReason) -> BlindCloseReasonCopy? {
        switch reason {
        case .dispatchWindowExpired:
            return .init(reason: "没有陪跑员接下这次预约。", nextStep: "可以重新预约，也可以换一个时间。")
        case .introCallWindowTooShort:
            return .init(reason: "离开跑时间太近，来不及先通电话，系统没有继续找人。",
                         nextStep: "可以重新预约一个晚一些的时间。")
        case .introCallFailedWindowTooShort:
            // 不提「通话没谈成」：无声拒绝，只说时间不够。
            return .init(reason: "离开跑时间太近，来不及再通一次电话，系统没有继续找人。",
                         nextStep: "可以重新预约一个晚一些的时间。")
        case .introCallRoundsExhausted:
            return .init(reason: "电话沟通的次数用完了，这次预约没有约成。", nextStep: rebook)
        case .startTimeLongPassed:
            return .init(reason: "约定的开跑时间已经过去很久，一直没有找到陪跑员，系统不再找人了。", nextStep: rebook)
        case .finishedBlindConfirmed, .finishedByVolunteer, .finishedByVolunteerUnconfirmed,
             .finishedByBlindVolunteerOffline, .autoCompleted, .csCompleted, .blindCancelled,
             .blindCancelledAfterArrival, .blindNoShow, .matchTimeout, .rematchLimitReached,
             .emergencyUnresolved, .csCancelled, .systemForceClosed, .accountSuspended, .unknown:
            return nil
        }
    }
}

extension OrderDetailResponse {
    /// 这一单的结束原因与下一步。`nil` = 原因不详（旧单、不认识的值、状态对不上），页面照旧。
    var blindCloseReasonCopy: BlindCloseReasonCopy? {
        BlindCloseReasonCopy.make(reason: closeReason, status: status)
    }
}
