import Foundation

// MARK: - 出发点附近有没有陪跑员（#1046）

extension BlindBookingViewModel {
    /// 拿去查的出发点。`nil` = 没有可信坐标，不查。
    var nearbyVolunteersStartPoint: NearbyVolunteersStartPoint? {
        guard let place = resolvedStartPlace else { return nil }
        // 定位还没回来时 `currentResolvedPlace` 可能是演示坐标：拿它查，说的是别人那个城市有没有人。
        guard place.source != .demoDefault || allowsDemoFallbackAsStartPoint else { return nil }
        return NearbyVolunteersStartPoint(
            selectedPlaceID: selectedStartPlace?.id, latitude: place.latitude, longitude: place.longitude
        )
    }

    /// 进约跑页和出发点变化时调；同一个出发点只查一次。
    /// 没有坐标、请求失败、旧后端 404 一律不显示卡片，也不报错：这只是提示，不拦下单。
    func refreshNearbyVolunteers() async {
        guard let point = nearbyVolunteersStartPoint else {
            queriedNearbyStartPoint = nil
            nearbyVolunteersNotice = nil
            return
        }
        if let queried = queriedNearbyStartPoint, point.isSameStart(as: queried) { return }
        // 换了地点就先撤下旧卡，别让上一个出发点的结论挂在新出发点上。
        // 当前定位只是挪远了：等结果回来再换，免得读屏焦点停着的卡片闪一下。
        if queriedNearbyStartPoint?.selectedPlaceID != point.selectedPlaceID { nearbyVolunteersNotice = nil }
        queriedNearbyStartPoint = point
        let response = try? await appState?.orders.nearbyVolunteers(latitude: point.latitude, longitude: point.longitude)
        // 请求在路上时出发点又换了：这份结果作废。
        guard queriedNearbyStartPoint == point else { return }
        nearbyVolunteersNotice = response.flatMap { NearbyVolunteersNotice($0) }
    }
}
