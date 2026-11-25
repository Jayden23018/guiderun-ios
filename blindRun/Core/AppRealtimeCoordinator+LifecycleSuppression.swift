import Foundation

/// 一条已到达、已登记订单的状态推送。生命周期横幅用它判断「订单页已经在播这一次变化」。
struct RecentLifecycleUpdate: Equatable {
    let orderID: Int64
    let status: RunOrderStatus
    let date: Date
}

/// 先到、等状态推送来配对的生命周期通知。
struct HeldLifecycleNotification {
    let id: UUID
    let status: RunOrderStatus
    let orderID: Int64?
    let notification: RealtimeForegroundNotification
    let type: String
    let task: Task<Void, Never>
}

// MARK: - 生命周期横幅的压制（#1011）
//
// 订单页自己会播状态变化，所以「跟状态变化说同一件事」的那几条通知（`lifecycleStatus` 那 8 种）不再弹一遍。
//
// 旧写法是「手上有任何一张登记的活跃订单就压」，别的订单的通知也被吞：盲人约了两张单，
// 第二张被取消、没人接，一个字都听不到；陪跑员在跑一张单时另一张预约被取消同理。
//
// 新判据：**只压「这条通知所属的订单此刻正被订单页跟着」的那一条。**
// 后端这 8 种通知的信封**不带 `orderId`**（`NotificationService.sendNotification` 只在调用方传
// `structuredFields` 时才加，这 8 处都传 null），但每一条都紧跟一条带 `orderId` 的
// `ORDER_STATUS_CHANGED`（先通知、后状态，同一事务）。所以用那条状态推送当「这是哪一单」的凭据：
//   1. 状态推送已经先到（重连补读等）→ 配对消耗，压掉这条横幅；
//   2. 还没到，但有登记的单**可能**迁到这个状态（`isDirectlyFollowed`）→ 先扣住 `lifecycleHoldDelay`，
//      等状态推送来配对；配上就压，到点没配上就照常弹；
//   3. 没有这样的单（通知属于订单页没在跟的单）→ 立刻弹。
// 通知若将来带上 `orderId`，同样走这三步，只是按单号配对。
//
// ⚠️ **未知 `eventType` 一律不压**（`lifecycleStatus` 返回 nil）：多听一遍好过一个字都听不到。
extension AppRealtimeCoordinator {
    /// 返回 `true` = 这条通知已被压掉或已扣住（由本方法负责之后弹不弹），调用方不再入队。
    func deferOrSuppressLifecycleNotification(
        status: RunOrderStatus,
        orderID: Int64?,
        notification: RealtimeForegroundNotification,
        type: String
    ) -> Bool {
        pruneRecentLifecycleUpdates()
        if let index = recentLifecycleUpdates.firstIndex(where: {
            $0.status == status && (orderID == nil || $0.orderID == orderID)
        }) {
            recentLifecycleUpdates.remove(at: index)
            return true
        }
        guard hasTrackedOrderThatMayBecome(status, orderID: orderID) else { return false }

        let delay = lifecycleHoldDelay
        let id = UUID()
        let task = Task { [weak self] in
            try? await Task.sleep(nanoseconds: UInt64(max(0, delay) * 1_000_000_000))
            guard !Task.isCancelled else { return }
            self?.releaseHeldLifecycleNotification(id: id)
        }
        heldLifecycleNotifications.append(
            HeldLifecycleNotification(id: id, status: status, orderID: orderID, notification: notification, type: type, task: task)
        )
        return true
    }

    /// 状态推送（只来自登记过的单）到达：先配对扣住的通知，配不上再记下来等通知。
    func noteLifecycleUpdate(orderID: Int64, status: RunOrderStatus, at date: Date) {
        if let index = heldLifecycleNotifications.firstIndex(where: {
            $0.status == status && ($0.orderID == nil || $0.orderID == orderID)
        }) {
            heldLifecycleNotifications[index].task.cancel()
            heldLifecycleNotifications.remove(at: index)
            return
        }
        // 只记 8 种生命周期通知会宣布的状态，且顺手清过期的：别的状态推送没有横幅可配，留着只会误压后来的。
        guard Self.lifecycleNotificationStatuses.contains(status) else { return }
        pruneRecentLifecycleUpdates()
        recentLifecycleUpdates.append(RecentLifecycleUpdate(orderID: orderID, status: status, date: date))
    }

    private static let lifecycleNotificationStatuses: Set<RunOrderStatus> = [
        .pendingAccept, .driverEnRoute, .driverArrived, .completed, .cancelled, .rematching, .noVolunteer
    ]

    private func hasTrackedOrderThatMayBecome(_ status: RunOrderStatus, orderID: Int64?) -> Bool {
        if let orderID { return activeOrderIDs.contains(orderID) }
        // 登记了但还没拿到状态的单，当作可能。
        return activeOrderIDs.contains { activeOrderStatuses[$0]?.isDirectlyFollowed(by: status) ?? true }
    }

    private func pruneRecentLifecycleUpdates() {
        let cutoff = now().addingTimeInterval(-lifecycleNotificationSuppressionWindow)
        recentLifecycleUpdates.removeAll { $0.date < cutoff }
    }

    private func releaseHeldLifecycleNotification(id: UUID) {
        guard let index = heldLifecycleNotifications.firstIndex(where: { $0.id == id }) else { return }
        let held = heldLifecycleNotifications.remove(at: index)
        enqueue(held.notification, type: held.type)
    }
}
