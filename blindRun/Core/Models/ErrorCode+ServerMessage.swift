import Foundation

// 从 `ErrorModels.swift` 原样搬出（SwiftLint 棘轮 #488：那个文件只许变短），行为零改动。
extension ErrorCode {
    /// 识别出这个码之后，仍优先念后端 `message`（非空时）。
    ///
    /// 默认是本地文案优先：后端 message 常是开发口径（「当前订单状态不允许该操作」）。
    /// 只有契约明写「message 可直接朗读、且含本地算不出的信息」的码才进这里。
    var prefersServerMessage: Bool {
        switch self {
        case .blindCancelTooEarly, .accountSuspended, .supportTicketLimitExceeded: return true
        // 时间类码（#659、#902）：后端 `OrderLifecycleService` 的 message 带最早可操作的时刻，本地文案说不出。
        case .departureTooEarly, .serviceStartTooEarly, .endWaitTooEarly, .blindConfirmationPending, .blindSafetyConfirmationPending: return true
        case .orderServiceNotOpen, .orderOutsideOpenArea, .appointmentOutsideDutyHours: return true
        // backend#1010：未满 18 周岁，message 是整句可朗读的原因。
        case .underageNotAllowed: return true
        // backend#1057：`IllegalArgumentException` 的统一出口，message 都是写给用户的中文
        // （「姓名需与实名认证一致，当前无法修改」「时段开始晚于结束」……）。固定文案会把原因吞掉，读屏用户只能听到这一句。
        case .badRequest: return true
        // 契约（#524）：收藏自己拉黑的人时 message 是「你已拉黑对方，请先解除」，本地文案说不出这句。
        case .favoriteVolunteerNotEligible: return true
        default: return false
        }
    }

    /// 念完后端 `message` 之后补的一句。后端那句没有说清的部分在这里，后端原文一个字不动。
    var serverMessageSupplement: String? {
        switch self {
        case .accountSuspended: return AccountSuspensionCopy.supplement
        // 后端那句只说「对方」。两人此刻站在一起，说出跑者那一端的按钮名，陪跑员可以直接告诉对方。
        case .blindConfirmationPending: return "可以请跑者在手机上按「开始跑步」。"
        default: return nil
        }
    }
}
