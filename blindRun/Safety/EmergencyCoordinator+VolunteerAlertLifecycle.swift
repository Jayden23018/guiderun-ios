import Foundation

// 陪跑员端求助警报什么时候收起（OpenSpec `volunteer-alert-clears-when-emergency-ends`）。
//
// 后端在求助结束（跑者撤销、客服结案）时不给陪跑员推任何事件，而 `refreshVolunteerAlert` 此前只在
// 回前台、WS 重连时调：App 一直开着，确认后的红条就永远挂着（负责人 2026-11-25 真机反馈）。
extension EmergencyCoordinator {
    /// 警报显示期间多久问一次 `GET /api/emergency/active`。
    /// 20 秒：求助结束后红条最多多挂这么久；陪跑员一次求助通常只看几分钟，每分钟 3 次请求可以接受。
    /// 后端给陪跑员推「求助已结束」之后，这里退成兜底，可以放长。
    static let volunteerAlertRefreshInterval: TimeInterval = 20

    /// 警报还在就隔一段问一次后端，警报没了或任务被取消就返回。没有警报时立刻返回，不发请求。
    func keepVolunteerAlertFresh(
        safety: any SafetyServing,
        interval: TimeInterval = EmergencyCoordinator.volunteerAlertRefreshInterval,
        sleep: @MainActor (TimeInterval) async throws -> Void = { try await Task.sleep(nanoseconds: UInt64($0 * 1_000_000_000)) }
    ) async {
        while volunteerAlert != nil {
            do { try await sleep(interval) } catch { return }
            guard volunteerAlert != nil, !Task.isCancelled else { return }
            await refreshVolunteerAlert(safety: safety)
        }
    }

    /// 警报挂着的那一单收到状态推送。
    ///
    /// 已取消、暂无陪跑员、回到匹配：陪跑员已不在这一单上，对这条求助也做不了什么，立刻收起。
    /// 已完成**不**在本地收起：完成后 `sosWindowEndsAt` 之前跑者仍能求助（#1016），只能问后端。
    func handleVolunteerAlertOrderStatus(orderID: Int64, status: RunOrderStatus, safety: any SafetyServing) async {
        guard let alert = volunteerAlert, alert.orderID == orderID else { return }
        switch status {
        case .cancelled, .noVolunteer, .pendingMatch, .rematching:
            volunteerAlert = nil
        case .completed:
            await refreshVolunteerAlert(safety: safety)
        case .pendingIntroCall, .scheduledConfirmed, .pendingAccept, .inProgress,
             .driverEnRoute, .driverArrived, .unknown:
            return
        }
    }
}

extension EmergencySafetyCopy {
    /// 警报收起时念的一句。同一句覆盖「求助已结束」和「这一单已不由你陪跑」两种原因：
    /// 客户端分不清是哪一种时，不能替后端说「已结束」。
    static let volunteerAlertCleared = "求助提醒已收起：这次求助已结束，或这一单已不由你陪跑。"
}
