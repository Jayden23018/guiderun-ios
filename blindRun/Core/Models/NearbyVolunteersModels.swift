import CoreLocation
import Foundation

// MARK: - 出发点附近有没有陪跑员（#1046，后端 blind-run-backend#1079）

/// `GET /api/orders/nearby-volunteers` 的 `data`。后端只回答有或没有，不给人数。
struct NearbyVolunteersResponse: Codable, Sendable, Equatable {
    let hasNearbyVolunteers: Bool
    /// 后端判定用的半径（公里）。界面不自己拼这个数，要说就由 `hint` 说。
    let radiusKm: Int?
    /// 没人时是可以直接显示和播报的一句话；有人时为 `null`。
    let hint: String?
}

/// 约跑页那张提示卡。只提示，不拦下单。
struct NearbyVolunteersNotice: Equatable {
    static let title = "目前附近无志愿者"
    static let changeStartPlace = "换个出发点"

    let hint: String

    var spokenLabel: String { "提示，\(Self.title)。\(hint)" }

    /// 结果回来时主动念的话。结论放最前面：看不见屏幕的人第一句就听到附近没人。
    var speech: String { "\(Self.title)。\(hint)" }

    /// `nil` = 不显示：附近有人（标题是事实断言，有人时绝不说没人），或后端没给那句话。
    init?(_ response: NearbyVolunteersResponse) {
        guard !response.hasNearbyVolunteers, let hint = response.hint?.nilIfBlank else { return nil }
        self.hint = hint
    }
}

/// 查附近陪跑员用的出发点。
struct NearbyVolunteersStartPoint: Equatable {
    /// 当前定位漂在这个距离以内算同一个出发点（米）。远小于后端的判定半径（20 公里），
    /// 避免 GPS 每次更新都打一次接口（后端按用户限流）。
    static let sameStartDistanceMeters: CLLocationDistance = 1_000

    /// 用户选定地点的 id；`nil` = 当前定位。
    let selectedPlaceID: String?
    /// GCJ-02。
    let latitude: Double
    let longitude: Double

    func isSameStart(as other: NearbyVolunteersStartPoint) -> Bool {
        guard selectedPlaceID == other.selectedPlaceID else { return false }
        let distance = CLLocation(latitude: latitude, longitude: longitude)
            .distance(from: CLLocation(latitude: other.latitude, longitude: other.longitude))
        return distance < Self.sameStartDistanceMeters
    }
}
