import SwiftUI

// 跑者确认已在安全的地方，结束陪跑（后端 #902，iOS #1016）。按钮在跑步页第一张卡（`BlindFinishSafetyCard`）。
extension BlindOrderStatusViewModel {
    /// 调 `confirm-safe`，然后重拉订单：成功时状态推到 `COMPLETED`，完成那一句照常由 `apply` 念（这里不另念）；
    /// 失败时（多半是请求刚作废或订单已结束，或还有未结束的求助）重拉让按钮跟着收起，原因照念。
    ///
    /// 在途标记借 `isPerformingAction`（取消、继续等待也用它）：这一刻页面上没有别的动作会同时在途。
    func confirmSafe() async {
        guard let order, order.isAwaitingBlindSafetyConfirmation, let appState, !isPerformingAction else { return }
        isPerformingAction = true
        defer { isPerformingAction = false }
        var failure: String?
        do {
            try await appState.orders.confirmSafe(orderId: order.orderId)
        } catch let error as APIError {
            if error.endsSession { return }
            failure = error.localizedMessage
        } catch {
            failure = "没有结束成功，请再按一次。"
        }
        if let failure { speechService?.speakError(failure) }
        await loadOrder(orderId: order.orderId, speakChanges: true)
        // 排在重拉之后：`loadOrder` 开头会清掉 `errorMessage`。
        if let failure { errorMessage = failure }
    }

    /// 进页面第一次拿到订单时陪跑员已请求结束（杀掉 App 重开、或从首页点进来）：横幅那一句错过了，单独补一句。
    ///
    /// 不并进状态句：状态句按「状态 + 订单」去重，首页先念过跑步中，订单页这句整句会被挡掉，补的话跟着没了。
    /// 只认首次加载：页面开着时请求到达，全局安全横幅已经在念同一件事，再念就是两遍。
    /// 排在「按需」档：状态句（对方操作档）同一拍在念时排在它后面，不切断它。
    func announceFinishRequestOnFirstLoad(previousStatus: RunOrderStatus?, updated: OrderDetailResponse, speakChanges: Bool) {
        guard Self.announcesFinishRequestOnLoad(previousStatus: previousStatus, updated: updated, speakChanges: speakChanges) else { return }
        speechService?.speak(FinishSafetyCopy.blindStatusSuffix, priority: .onDemand)
    }

    nonisolated static func announcesFinishRequestOnLoad(
        previousStatus: RunOrderStatus?, updated: OrderDetailResponse, speakChanges: Bool
    ) -> Bool {
        speakChanges && previousStatus == nil && updated.isAwaitingBlindSafetyConfirmation
    }
}
