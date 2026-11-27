import Foundation

extension MockAPIClient {
    /// 出发点附近有没有陪跑员（#1046）。不是这条路径时返回 `nil`，交回主路由。
    /// Mock 不看坐标：默认有人（不出卡，其余用例不受影响），`AIDRUN_MOCK_NEARBY_VOLUNTEERS=none` 演附近没人。
    func routeNearbyVolunteers(method: HTTPMethod, path: String) throws -> Any? {
        guard path == "/api/orders/nearby-volunteers", method == .get else { return nil }
        guard mockToken != nil, !isAccountDeleted else { throw APIError.unauthorized }
        return Self.mockNearbyVolunteers(ProcessInfo.processInfo.environment["AIDRUN_MOCK_NEARBY_VOLUNTEERS"])
    }

    static func mockNearbyVolunteers(_ mode: String?) -> NearbyVolunteersResponse {
        let isEmpty = mode == "none"
        return NearbyVolunteersResponse(
            hasNearbyVolunteers: !isEmpty,
            radiusKm: 20,
            // 契约 `NearbyVolunteersResponse.hint` 的 `example`。
            hint: isEmpty ? "20 公里内暂时没有可接单的陪跑员。仍然可以预约，有人接单会通知你；也可以换一个出发点。" : nil
        )
    }
}
