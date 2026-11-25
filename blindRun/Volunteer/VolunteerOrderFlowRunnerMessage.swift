import Foundation

/// 跑者「给陪跑员留一句话」（订单详情 `messageToVolunteer`）在陪跑员订单页上的呈现（#1012）。
///
/// 后端有意不把留言放进推送正文（会上锁屏），所以它**只在 App 内**显示：约好之后到开跑之前的每一屏都出一行，
/// 内容原文照搬、不改写。留言被清空（空串 / 全空白）就不出这一行。
/// 不走 `disclosesBlindRunnerNotesToVolunteer` 闸：这一页只在接单之后才进得来，而且这句话本来就是写给他的。
enum VolunteerRunnerMessage {
    static let label = "跑者留言"
    static let rowID = "runnerMessage"

    /// 留言原文；清空了返回 nil。
    static func text(of order: OrderDetailResponse) -> String? {
        order.messageToVolunteer?.nilIfBlank
    }

    static func row(order: OrderDetailResponse) -> VolunteerOrderFlowPresentation.Row? {
        guard let text = text(of: order) else { return nil }
        return .init(
            id: rowID, label: label, value: text, detail: nil, action: nil,
            accessibilityLabel: "\(label)，\(text)", accessibilityHint: nil
        )
    }

    /// 留言变了要念的那一句。`nil` = 不念。
    ///
    /// - 第一次拿到订单（`previous == nil`）不念：页面上那一行读屏本来就读得到，进页面就念会抢在状态句前面。
    /// - 只在开跑之前念：跑步中不打断（那时留言已不在页面上）。
    /// - 变成空（清空）不念。
    static func announcement(previous: OrderDetailResponse?, current: OrderDetailResponse) -> String? {
        guard let previous, let now = text(of: current), now != text(of: previous) else { return nil }
        switch current.status {
        case .scheduledConfirmed, .pendingAccept, .driverEnRoute, .driverArrived:
            return "\(label)：\(now)"
        default:
            return nil
        }
    }
}

extension VolunteerOrderPhase {
    /// 这一阶段给哪几条快捷消息（#1012）。空 = 不出这一块。
    /// 已出发两条；已到达只留「再等我 5 分钟」—— 人已经到了再说「我快到了」是错话。后端两态都放行。
    var quickMessageCodes: [QuickMessageCode] {
        switch self {
        case .departed: return [.almostThere, .waitFiveMinutes]
        case .arrived: return [.waitFiveMinutes]
        default: return []
        }
    }
}

extension VolunteerOrderFlowCopy {
    /// 取消确认框的后果句。已到达（#1012）：跑者正在集合点等，要说清他会被告知。
    static func cancelMessage(for status: RunOrderStatus?) -> String {
        switch status {
        case .scheduledConfirmed, .pendingAccept, .driverEnRoute:
            return "此订单将转给其他陪跑员，之后不一定还能接回来。"
        case .driverArrived:
            return "此订单将转给其他陪跑员，跑者会被告知。"
        default:
            return "此订单将转给其他陪跑员。"
        }
    }
}

extension VolunteerOrderFlowPresentation {
    /// 约好 / 出发两屏信息块的开头：跑者、电话（有才出）、跑者留言（有才出）。
    static func runnerPhoneAndMessageRows(order: OrderDetailResponse) -> [Row] {
        [runnerRow(order: order), phoneRow(order: order), VolunteerRunnerMessage.row(order: order)].compactMap { $0 }
    }
}

extension VolunteerInServiceViewModel {
    /// 换上新订单；跑者留言变了就念一次（推送正文里没有留言，#1012）。
    func replaceOrder(with updated: OrderDetailResponse, speakingMessageChange: Bool) {
        let previous = order
        order = updated
        if speakingMessageChange, let sentence = VolunteerRunnerMessage.announcement(previous: previous, current: updated) {
            speechService?.speak(sentence)
        }
    }
}
