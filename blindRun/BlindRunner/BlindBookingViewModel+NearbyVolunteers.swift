import Foundation

// MARK: - 出发点附近有没有陪跑员（#1046）

extension BlindBookingViewModel {
    /// 拿去查的出发点。`nil` = 没有可信坐标，不查。
    var nearbyVolunteersStartPoint: NearbyVolunteersStartPoint? {
        guard let place = resolvedStartPlace else { return nil }
        // 演示坐标拿去查，说的是别人那个城市有没有人。`refreshCurrentLocation` 已经不缓存它，这里再挡一道。
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

    /// 附近没人时马上念出来（负责人 2026-11-27）。走 `speak` 不走只发给读屏的通告：只听 App 语音的人也要听到。
    /// 它会打断正在念的那句，所以那句接在后面重念：开场白按此刻的选择重拼（`currentEntry`），
    /// 别的话原样接上；上一个出发点的「没人」已经过时，不接。
    func speakNearbyVolunteersNotice(_ notice: NearbyVolunteersNotice, spokenEntry: String?, currentEntry: String) {
        guard let speechService else { return }
        var followUp = speechService.isSpeaking ? speechService.lastSpokenText : nil
        if followUp == spokenEntry, followUp != nil {
            followUp = currentEntry
        } else if followUp?.hasPrefix(NearbyVolunteersNotice.title) == true {
            followUp = nil
        }
        speechService.speak(notice.speech + (followUp ?? ""))
    }
}
