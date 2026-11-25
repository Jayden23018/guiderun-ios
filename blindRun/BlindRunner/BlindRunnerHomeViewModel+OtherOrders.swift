import Foundation

// MARK: - 首页其余几张预约跟着实时推送走（#1011）

// 以前只有最早那张（`activeOrder`）登记进实时协调器，第 2、3 张的状态推送到了也没人接：
// 卡片不刷新，横幅又被旧的压制规则吞掉，盲人全程不知道那张单被取消或没人接。
extension BlindRunnerHomeViewModel {
    /// 把 `otherOrders` 登记进协调器，并撤掉已经不在首页上的那几张。
    /// 只撤自己登记过的：订单页登记的单不归这里管。
    func syncOtherOrderRegistration(appState: AppState) {
        let coordinator = appState.realtimeCoordinator
        let shownIDs = Set(homeOrders.map(\.orderId))
        for order in otherOrders {
            coordinator.registerActiveOrder(order.orderId, status: order.status)
        }
        for id in registeredOtherOrderIDs.subtracting(shownIDs) {
            coordinator.unregisterActiveOrder(id)
        }
        registeredOtherOrderIDs = Set(otherOrders.map(\.orderId))
    }

    /// 其余几张里某一张的状态推送到了：卡片跟着变，走完的撤下，并念一句带开跑时间的话。
    ///
    /// 不走 `speakStatusChange`：它按 `lastSpokenStatus` 全 App 一份去重，两张单先后「已取消」第二句会被吞。
    /// 这里的调用方本身已按订单号配对，不需要那道去重。
    func applyRealtimeStatusToOtherOrder(_ update: RealtimeOrderStatusUpdate) {
        guard let index = otherOrders.firstIndex(where: { $0.orderId == update.orderId }) else { return }
        let updated = otherOrders[index].replacingStatus(with: update.toStatus)
        if updated.status.isActiveForBlindRunner {
            otherOrders[index] = updated
        } else {
            otherOrders.remove(at: index)
            registeredOtherOrderIDs.remove(updated.orderId)
            appState?.realtimeCoordinator.unregisterActiveOrder(updated.orderId)
        }
        let which = updated.plannedStartForAnnouncement.map { "\($0)的预约：" } ?? "另一张预约："
        let text = which + updated.blindRunnerAnnouncement()
        // 与最早那张同一道闸：这一单的订单页正开着、自己会念时，首页不再念第二遍。
        guard let tracker = appState?.realtimeCoordinator.orderLiveTracker else {
            speechService?.speak(text, priority: .counterpartAction)
            return
        }
        Task { @MainActor [weak self] in
            guard await tracker.pageAnnouncement(for: update, role: .blind) == .homeShouldSpeak else { return }
            self?.speechService?.speak(text, priority: .counterpartAction)
        }
    }

    /// App 回前台：重拉全部预约，补上后台时漏掉的变化。状态没变就不出声（切回来不该每次被念一遍）。
    func refreshOnForeground() async {
        guard case .loaded = orderLoadState else { return }
        let before = statusSnapshot
        let owed = owesStatusAnnouncement
        await loadActiveOrder(announcesStatus: false)
        owesStatusAnnouncement = owed
        if statusSnapshot != before { speakCurrentStatus() }
    }

    private var statusSnapshot: [String] {
        homeOrders.map { "\($0.orderId)-\($0.status.rawValue)" }
    }
}
