import Foundation

// 结束前确认跑者安全（后端 #902，iOS #1016）。
//
// 陪跑员按结束 → 后端记下请求、推跑者 `FINISH_SAFETY_CONFIRM_REQUESTED` → 跑者按「我已在安全的地方，结束陪跑」
// （`POST /api/orders/{id}/confirm-safe`）订单才完成；跑者一直没确认，陪跑员到 `unilateralFinishOpensAt` 之后再按一次即完成。
// 请求在后端定的时限后作废，`finishRequestedAt` 回到 null，两端都回到普通跑步中。
//
// 后端用配置 `app.order.finish-blind-confirm-timeout-minutes` 开关这道闸，默认关：关着时 `finish` 直接回 `completed=true`，
// 三个时刻恒为 null，下面每个判定都退回改动前的行为。
//
// 🔴 时刻只认后端下发，**客户端不拿请求时刻自己加分钟数**（契约原话）。

/// `POST /api/orders/{id}/finish` 的响应体：`{success, orderId, completed, unilateralFinishOpensAt}`。
struct FinishOrderResponse: Decodable, Sendable, Equatable {
    /// `true` = 订单已完成。缺键或类型不对时按 `true`：闸关着的后端、旧形状的 Mock 都是「调用即完成」，
    /// 与改动前的行为一致。判成 `false` 会让陪跑员停在一个永远等不到的「等对方确认」上。
    let completed: Bool
    /// 闸开着、这一下只是请求时，陪跑员最早可以单方面结束的时刻。
    let unilateralFinishOpensAt: String?

    init(completed: Bool, unilateralFinishOpensAt: String? = nil) {
        self.completed = completed
        self.unilateralFinishOpensAt = unilateralFinishOpensAt
    }

    private enum CodingKeys: String, CodingKey { case completed, unilateralFinishOpensAt }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        completed = (try? container.decodeIfPresent(Bool.self, forKey: .completed)) ?? true
        unilateralFinishOpensAt = (try? container.decodeIfPresent(String.self, forKey: .unilateralFinishOpensAt))?.nilIfBlank
    }
}

/// 陪跑员第一次按结束、后端只记下请求时，`complete()` 用它把这一结果从「已提交，等状态确认」那条路上分出来。
struct VolunteerFinishAwaitingBlind: Error, Equatable {
    let opensAt: String?
}

extension OrderDetailResponse {
    /// 跑者端：陪跑员已请求结束，在等跑者确认安全。只在 `IN_PROGRESS` 成立 —— 状态推到完成时，
    /// `replacingStatus` 会把旧的请求时刻带过去，确认按钮不能跟着留下。
    var isAwaitingBlindSafetyConfirmation: Bool {
        status == .inProgress && finishRequestedAt?.nilIfBlank != nil
    }

    /// 陪跑员端：已请求结束、在等跑者确认。判据是只发给陪跑员的 `unilateralFinishOpensAt`。
    var volunteerFinishOpensAt: Date? {
        guard status == .inProgress else { return nil }
        return unilateralFinishOpensAt?.nilIfBlank?.backendTimestamp
    }

    /// 完成后、`sosWindowEndsAt` 之前：跑者的求助仍挂在这一单上走云端（契约：「iOS 在 `IN_PROGRESS` 和这一刻之前都显示求助按钮」）。
    func isWithinPostFinishSOSWindow(now: Date) -> Bool {
        guard status == .completed, let until = sosWindowEndsAt?.nilIfBlank?.backendTimestamp else { return false }
        return now < until
    }

    /// 云端求助的唯一判据（`BlindHomeSOSMode.resolve` 与 `EmergencyCoordinator.trigger` 发送前复核都读它）。
    /// 陪跑员不变：只有 `IN_PROGRESS`。跑者多一段：完成后的求助窗口之内。
    func canTriggerEmergency(as role: UserRole, now: Date = Date()) -> Bool {
        if status.canTriggerEmergency(as: role) { return true }
        return role == .blind && isWithinPostFinishSOSWindow(now: now)
    }
}

/// 陪跑员端「等跑者确认安全」那张提示卡的内容。`nil` = 没在等，页面与改动前一样。
struct VolunteerFinishSafetyNotice: Equatable {
    let text: String
    /// 已到单方面结束的时刻。
    let canFinishNow: Bool

    static func resolve(order: OrderDetailResponse, now: Date) -> Self? {
        guard let opensAt = order.volunteerFinishOpensAt else { return nil }
        if now >= opensAt {
            return Self(text: FinishSafetyCopy.volunteerMayFinishNow, canFinishNow: true)
        }
        return Self(text: FinishSafetyCopy.volunteerWaiting(opensAt: opensAt), canFinishNow: false)
    }
}

enum FinishSafetyCopy {
    // MARK: 陪跑员

    static func volunteerWaiting(opensAt: Date) -> String {
        "已请对方确认是否在安全的地方。对方确认后陪跑自动结束；联系不上时，\(clock(opensAt))之后可以长按结束。"
    }

    /// 按下结束、后端只记下请求时念的那句（屏幕上那张卡同一句）。
    static func volunteerRequested(opensAt: String?) -> String {
        guard let date = opensAt?.backendTimestamp else {
            return "已请对方确认是否在安全的地方。对方确认后陪跑自动结束。"
        }
        return volunteerWaiting(opensAt: date)
    }

    static let volunteerMayFinishNow = "对方还没确认是否在安全的地方。联系不上的话，现在可以长按结束陪跑。"

    /// 409 `BLIND_SAFETY_CONFIRMATION_PENDING` 的后端 message 为空时才念（`prefersServerMessage`）。
    static let pendingFallback = "已请对方确认是否在安全的地方，请等对方确认后再结束。"

    // MARK: 跑者

    static let blindCardTitle = "陪跑员请求结束陪跑"
    static let blindCardBody = "如果你已经在安全的地方，按下面的按钮结束。还没到就先不要按，告诉陪跑员继续陪你。"
    static let blindConfirmButton = "我已在安全的地方，结束陪跑"
    static let blindConfirmingButton = "正在结束陪跑"

    /// 「重复当前状态」与冷启动的状态播报末尾补的一句：没有它，杀掉 App 重开的跑者不会知道页面上多了这个按钮。
    static let blindStatusSuffix = "陪跑员请求结束陪跑。如果你已经在安全的地方，按页面上的「\(blindConfirmButton)」；还没到就先不要按。"

    private static func clock(_ date: Date) -> String {
        DateFormatter.aidRunDisplayClock.string(from: date)
    }
}
