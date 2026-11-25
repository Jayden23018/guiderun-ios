import Foundation

// 从 `SpeechService.swift` 拆出来（SwiftLint 棘轮：文件已超上限，不许变大）。
extension SpeechService {
    /// 播报订单状态变化（防重复）
    /// 只在状态真正变化时播报，避免轮询时反复播报同一状态。
    ///
    /// 触觉挂在这里而不是各个业务分支上：这两个重载是**状态变化播报的唯一 funnel**
    /// （`BlindOrderStatusView.apply` 与首页都从这儿过），且防重复的 guard 已经在这一层，
    /// 挂在下游会跟着轮询反复震。触觉是语音的冗余通道，两者必须同生同灭 ——
    /// 单独一下震动没有语义，用户分不出是接单还是取消。见 `HapticFeedback`。
    @discardableResult
    func speakStatusChange(_ status: RunOrderStatus, orderID: Int64? = nil) -> Bool {
        guard !isDuplicateStatus(status, orderID: orderID) else { return false }
        lastSpokenStatus = status
        lastSpokenOrderID = orderID
        speak(text: Self.statusAnnouncement(for: status))
        status.haptic.map(HapticFeedback.play)
        return true
    }

    @discardableResult
    func speakStatusChange(
        _ status: RunOrderStatus,
        text: String,
        priority: AnnouncementPriority = .counterpartAction,
        orderID: Int64? = nil
    ) -> Bool {
        guard !isDuplicateStatus(status, orderID: orderID) else { return false }
        lastSpokenStatus = status
        lastSpokenOrderID = orderID
        speak(text: text, priority: priority)
        status.haptic.map(HapticFeedback.play)
        return true
    }

    /// 这一态已经由别处用自己的整句念过了（陪跑员订单页的跑者取消那句，#462）：只记下去重键、不念，
    /// 让随后到的通用状态句被 `speakStatusChange` 挡掉。整句本身照常走 `speak` ——
    /// 不让它也过去重，免得上一单留下的同一个键把这一单「不算你的取消」吞掉。
    func markStatusAnnounced(_ status: RunOrderStatus, orderID: Int64? = nil) {
        lastSpokenStatus = status
        lastSpokenOrderID = orderID
    }

    /// 同状态且**不能确定是两张不同的单**才算重复。任一边没带订单号时退回只比状态（老调用方行为不变）；
    /// 两边都带了且不同，就是另一张单的同一个状态，要念。
    func isDuplicateStatus(_ status: RunOrderStatus, orderID: Int64?) -> Bool {
        guard status == lastSpokenStatus else { return false }
        guard let orderID, let lastSpokenOrderID else { return true }
        return orderID == lastSpokenOrderID
    }
}
