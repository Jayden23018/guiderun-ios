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
}
