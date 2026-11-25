import CoreLocation
import SwiftUI

/// 陪跑员端的全局求助警报（#1012）。挂在陪跑员标签栏根上，盖住 App 里的任何一页。
///
/// 此前警报只挂在订单页（`VolunteerInServiceView`）：跑者按了求助，陪跑员正好在首页、记录或「我的」，
/// 只有一条 5 秒横幅。现在全屏盖层不管他在哪一页都会弹出，直到他确认或求助被本人 / 客服结束。
///
/// 🔴 仍然**没有关闭按钮**，也没有「误触」：陪跑员不能撤销跑者的求助（后端 403
/// `EMERGENCY_VOLUNTEER_CANNOT_DISMISS`，见 `VolunteerEmergencyAlertView`）。
///
/// 订单页不再自己挂盖层 —— 两层同时挂会让 SwiftUI 在同一个视图层级上重复呈现。
/// 订单页里那条「确认需要帮助」横幅（`emergencySection`）保留，确认之后它仍承载求助结果文案。
struct VolunteerGlobalEmergencyAlert: ViewModifier {
    @ObservedObject var coordinator: EmergencyCoordinator
    @EnvironmentObject private var appState: AppState
    @EnvironmentObject private var speechService: SpeechService
    @EnvironmentObject private var locationService: LocationService
    @EnvironmentObject private var amapGeocodingService: AMapGeocodingService

    @State private var peer: VolunteerEmergencyAlertPeer?
    @State private var isAcknowledging = false

    static let acknowledgeFailure = "确认失败，请重试。若情况危急请立即拨打120或110。"

    func body(content: Content) -> some View {
        content
            .volunteerEmergencyAlertCover(
                coordinator: coordinator,
                peerName: peer?.name,
                peerPhone: peer?.phone,
                deviceCoordinate: locationService.currentLocation,
                isAcknowledging: isAcknowledging,
                reverseGeocode: { await amapGeocodingService.reverseGeocode(coordinate: $0)?.title },
                serverAddress: { try? await appState.safety.orderLocationAddress(orderId: $0) },
                onAcknowledge: { eventID in Task { await acknowledge(eventID: eventID) } }
            )
            // 取不到订单时（冷启动恢复、网络慢）不阻塞警报：名字与电话缺省，其余信息照出。
            .task(id: coordinator.volunteerAlert?.orderID) {
                guard let orderID = coordinator.volunteerAlert?.orderID else {
                    peer = nil
                    return
                }
                peer = VolunteerEmergencyAlertPeer.make(from: try? await appState.orders.orderDetail(orderId: orderID))
            }
    }

    private func acknowledge(eventID: Int64) async {
        guard !isAcknowledging else { return }
        isAcknowledging = true
        let succeeded = await coordinator.acknowledgeAsVolunteer(eventID: eventID, safety: appState.safety)
        isAcknowledging = false
        if succeeded {
            speechService.speak(EmergencySafetyCopy.volunteerAcknowledged)
        } else {
            speechService.speakError(Self.acknowledgeFailure)
        }
    }
}

/// 警报上要显示的跑者称呼与拨号号码，取自警报那一单的详情。
struct VolunteerEmergencyAlertPeer: Equatable {
    let name: String?
    /// 全号，只进 `tel:`（`VolunteerEmergencyAlertView` 的约束）。
    let phone: String?

    static func make(from order: OrderDetailResponse?) -> Self? {
        guard let order else { return nil }
        return Self(name: order.blindName?.nilIfBlank, phone: order.blindPhone?.nilIfBlank)
    }
}

extension View {
    func volunteerGlobalEmergencyAlert(coordinator: EmergencyCoordinator) -> some View {
        modifier(VolunteerGlobalEmergencyAlert(coordinator: coordinator))
    }
}
