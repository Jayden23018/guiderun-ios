import Foundation

// MARK: - 通话这一轮为什么结束 / 取消的预设原因（后端 #1051 / backend#1055）

/// 陪跑员端 `INTRO_CALL_CLOSED*` 通知信封里的 `closeCause`。**开放枚举**：不认识的值按 `roundEnded`。
///
/// 🚨 `roundEnded` 是**中性**的：它不说是谁的决定，跑者换人也落在它上面。
/// 页面文案不许补成「对方不合适」之类的话，也不许因为它「不是超时」就推断什么 ——
/// 这个功能存在的意义就是让退出不带评判（`VolunteerIntroCallOutcome.closed`）。
/// 横幅正文读后端的 `body` / `ttsText`（四种成因各有现成的话），客户端不自己拼。
nonisolated enum IntroCallCloseCause: Equatable, Sendable {
    case blindCancelled
    case windowTimeout
    case windowTooShort
    case roundEnded

    init(rawValue: String?) {
        switch rawValue?.uppercased() {
        case "BLIND_CANCELLED": self = .blindCancelled
        case "WINDOW_TIMEOUT": self = .windowTimeout
        case "WINDOW_TOO_SHORT": self = .windowTooShort
        default: self = .roundEnded
        }
    }
}

/// 取消订单时可附的预设原因（`POST /api/orders/{id}/cancel` 请求体 `{"reason": "<值>"}`，可选）。
///
/// **请求体里是闭合枚举**：只能发下面列出的值；用了对方角色的值后端回 400。
/// 对方收到的取消通知里的 `cancelReason` 是开放枚举，另按字符串读（`WSAppNotification.cancelReason`）。
nonisolated enum OrderCancelReason: String, Encodable, CaseIterable, Sendable {
    // 跑者
    case blindPlanChanged = "BLIND_PLAN_CHANGED"
    case blindUnwell = "BLIND_UNWELL"
    case blindWeather = "BLIND_WEATHER"
    case blindArrangedElsewhere = "BLIND_ARRANGED_ELSEWHERE"
    case blindOther = "BLIND_OTHER"
    // 陪跑员
    case volunteerScheduleConflict = "VOLUNTEER_SCHEDULE_CONFLICT"
    case volunteerUnwell = "VOLUNTEER_UNWELL"
    case volunteerWeather = "VOLUNTEER_WEATHER"
    case volunteerDelayed = "VOLUNTEER_DELAYED"
    case volunteerOther = "VOLUNTEER_OTHER"

    var isForBlindRunner: Bool { rawValue.hasPrefix("BLIND_") }

    /// 给人看 / 朗读的名字（后端契约里的中文名）。
    var displayName: String {
        switch self {
        case .blindPlanChanged: return "安排有变"
        case .blindUnwell, .volunteerUnwell: return "身体不舒服"
        case .blindWeather, .volunteerWeather: return "天气不合适"
        case .blindArrangedElsewhere: return "已经另外安排好了"
        case .blindOther, .volunteerOther: return "其他"
        case .volunteerScheduleConflict: return "时间冲突了"
        case .volunteerDelayed: return "路上耽搁，赶不过去"
        }
    }
}

/// `POST /api/orders/{id}/cancel` 的请求体。不附原因时不发请求体（与以前一样）。
nonisolated struct CancelOrderRequest: Encodable, Sendable {
    let reason: OrderCancelReason
}
