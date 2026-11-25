import Foundation

// 「结束前确认跑者安全」在 Mock 里的镜像（后端 #902，iOS #1016）。照后端 `OrderLifecycleService.finishOrder` /
// `confirmSafe` / `FinishSafetyPolicy`：
// - 闸关着（`finishBlindConfirmTimeout == 0`，默认，与线上一致）：`finish` 调用即完成，与改动前一样。
// - 闸开着：第一次 `finish` 只记请求、回 `completed=false`；到 `unilateralFinishOpensAt` 之前再调回 409
//   `BLIND_SAFETY_CONFIRMATION_PENDING`；之后再调即完成。`confirm-safe` 即完成。请求在 2 × 超时后作废。
// - 完成后给跑者一个求助窗口 `sosWindowEndsAt`（后端默认 30 分钟）。
//
// 时刻按查看者下发：`unilateralFinishOpensAt` 只给陪跑员，`sosWindowEndsAt` 只给跑者（记忆 `mock-fabricates-fields-the-backend-never-sends`）。
extension MockAPIClient {
    /// 打开 Mock 的确认闸：值是确认超时的**秒数**（后端配的是分钟；Mock 用秒，好让单方面结束在开发期等得到）。
    static let finishBlindConfirmTimeoutEnvironmentKey = "AIDRUN_MOCK_FINISH_BLIND_CONFIRM_SECONDS"
    /// 后端 `app.order.post-finish-sos-window-minutes` 的默认值。
    static let postFinishSOSWindow: TimeInterval = 30 * 60
    /// 跑者端 Mock 面板「打开确认闸」用的超时：与负责人定的线上值同为 10 分钟。
    static let demoFinishBlindConfirmTimeout: TimeInterval = 10 * 60

    static func initialFinishBlindConfirmTimeout(
        environment: [String: String] = ProcessInfo.processInfo.environment
    ) -> TimeInterval {
        environment[finishBlindConfirmTimeoutEnvironmentKey].flatMap(TimeInterval.init).map { max(0, $0) } ?? 0
    }

    /// `POST /finish` 与 `POST /confirm-safe` 两条路由。合成一个入口：路由函数的复杂度已到 SwiftLint 棘轮的上限。
    func handleFinishSafetyRoute(method: HTTPMethod, path: String, orderId: Int64) throws -> FinishOrderResponse? {
        guard method == .post else { return nil }
        if path.hasSuffix("/finish") { return try handleFinishRequest(orderId: orderId) }
        if path.hasSuffix("/confirm-safe") { return try handleConfirmSafe(orderId: orderId) }
        return nil
    }

    /// - Parameter byVolunteer: 跑者调 `finish` 是「陪跑员掉线时跑者结束」，后端不走确认闸（`byBlind` 分支）。
    ///   跑者端 Mock 面板代打陪跑员那一下传 `true`。
    func handleFinishRequest(orderId: Int64, byVolunteer: Bool? = nil) throws -> FinishOrderResponse {
        guard let index = orders.firstIndex(where: { $0.orderId == orderId }) else {
            throw APIError.serverError(ErrorResponse(code: "ORDER_NOT_FOUND", message: "订单不存在"))
        }
        let now = Date()
        expireFinishRequestIfNeeded(at: index, now: now)
        let timeout = finishBlindConfirmTimeout
        guard timeout > 0, byVolunteer ?? (mockRole != .blind), orders[index].status.canFinishService else {
            return try completeMockFinish(orderId: orderId, now: now)
        }
        guard let requestedAt = finishRequestTimes[orderId] else {
            finishRequestTimes[orderId] = now
            let opensAt = Self.stamp(now.addingTimeInterval(timeout))
            orders[index].finishRequestedAt = Self.stamp(now)
            orders[index].unilateralFinishOpensAt = mockRole == .blind ? nil : opensAt
            return FinishOrderResponse(completed: false, unilateralFinishOpensAt: opensAt)
        }
        let opensAt = requestedAt.addingTimeInterval(timeout)
        guard now >= opensAt else {
            let clock = DateFormatter.aidRunDisplayClock.string(from: opensAt)
            throw APIError.serverError(ErrorResponse(
                code: "BLIND_SAFETY_CONFIRMATION_PENDING",
                message: "已请对方确认是否在安全的地方，请等对方确认；若一直联系不上，\(clock)之后可以直接结束"
            ))
        }
        return try completeMockFinish(orderId: orderId, now: now)
    }

    func handleConfirmSafe(orderId: Int64) throws -> FinishOrderResponse {
        guard let index = orders.firstIndex(where: { $0.orderId == orderId }) else {
            throw APIError.serverError(ErrorResponse(code: "ORDER_NOT_FOUND", message: "订单不存在"))
        }
        // 幂等：已完成的单重复调用回 200（契约）。
        if orders[index].status == .completed { return FinishOrderResponse(completed: true) }
        expireFinishRequestIfNeeded(at: index, now: Date())
        guard orders[index].status == .inProgress, finishRequestTimes[orderId] != nil else {
            throw APIError.serverError(ErrorResponse(
                code: "ORDER_STATUS_NOT_ALLOWED", message: "陪跑员还没有请求结束"))
        }
        return try completeMockFinish(orderId: orderId, now: Date())
    }

    /// 轮询读详情前调一次：请求过了 2 × 超时就作废，`finishRequestedAt` 回到 null（契约「请求自动失效」）。
    func expireFinishRequestIfNeeded(orderId: Int64) {
        guard let index = orders.firstIndex(where: { $0.orderId == orderId }) else { return }
        expireFinishRequestIfNeeded(at: index, now: Date())
    }

    #if DEBUG
    /// 跑者端 Mock 面板「模拟陪跑员请求结束」：代陪跑员按一次结束。
    func simulateVolunteerFinishForTesting(orderId: Int64) throws -> FinishOrderResponse {
        try handleFinishRequest(orderId: orderId, byVolunteer: true)
    }

    /// 跑者端 Mock 面板的开关：在关着（线上现状）与 10 分钟之间切换。
    func toggleFinishSafetyGateForTesting() -> Bool {
        finishBlindConfirmTimeout = finishBlindConfirmTimeout > 0 ? 0 : Self.demoFinishBlindConfirmTimeout
        return finishBlindConfirmTimeout > 0
    }
    #endif

    private func expireFinishRequestIfNeeded(at index: Int, now: Date) {
        let orderId = orders[index].orderId
        guard let requestedAt = finishRequestTimes[orderId] else { return }
        let stillValid = orders[index].status == .inProgress
            && now < requestedAt.addingTimeInterval(2 * finishBlindConfirmTimeout)
        guard !stillValid else { return }
        finishRequestTimes[orderId] = nil
        orders[index].finishRequestedAt = nil
        orders[index].unilateralFinishOpensAt = nil
    }

    private func completeMockFinish(orderId: Int64, now: Date) throws -> FinishOrderResponse {
        _ = try handleFinish(orderId: orderId)
        finishRequestTimes[orderId] = nil
        if let index = orders.firstIndex(where: { $0.orderId == orderId }), mockRole == .blind {
            orders[index].sosWindowEndsAt = Self.stamp(now.addingTimeInterval(Self.postFinishSOSWindow))
        }
        return FinishOrderResponse(completed: true)
    }

    private static func stamp(_ date: Date) -> String {
        DateFormatter.aidRunBackendLocalDateTime.string(from: date)
    }
}
