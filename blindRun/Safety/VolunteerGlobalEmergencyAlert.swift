import Combine
import CoreLocation
import SwiftUI
import UIKit

/// 陪跑员端的全局求助警报（#1012）。挂在陪跑员标签栏根上，任何页、任何 sheet 之上都看得见。
///
/// **为什么是独立 `UIWindow` 而不是 `fullScreenCover`**：SwiftUI 的 sheet / cover 同一个视图层级同时只能呈现一个。
/// 陪跑员正开着订单页的 sheet（求助面板、取消确认……）时，根上的 cover 弹不出来，而那恰是最需要它的时刻。
/// 独立 window 不走 SwiftUI 的呈现机制，也不会被 sheet 盖住。
///
/// 两种形态（`mode`，纯函数 `Mode.resolve`）：
/// - `.full`：有未确认的告警，整屏盖层 + 警报音。**没有关闭按钮**：陪跑员不能撤销跑者的求助
///   （后端 403 `EMERGENCY_VOLUNTEER_CANNOT_DISMISS`）。
/// - `.bar`：已确认但求助没结束，屏幕顶上一条常驻红条，点它回到警报（不再响）。求助结束（`volunteerAlert` 置 nil）时消失。
///
/// 订单页不再自己挂盖层。订单页里那条「确认需要帮助」横幅（`emergencySection`）保留，确认之后它仍承载求助结果文案。
struct VolunteerGlobalEmergencyAlert: ViewModifier {
    @ObservedObject var coordinator: EmergencyCoordinator
    @EnvironmentObject private var appState: AppState
    @EnvironmentObject private var speechService: SpeechService
    @EnvironmentObject private var locationService: LocationService
    @EnvironmentObject private var amapGeocodingService: AMapGeocodingService

    @StateObject private var presenter = VolunteerEmergencyWindowPresenter()

    static let acknowledgeFailure = "确认失败，请重试。若情况危急请立即拨打120或110。"

    private var mode: VolunteerEmergencyWindowMode {
        .resolve(alert: coordinator.volunteerAlert, isReviewing: presenter.isReviewing)
    }

    func body(content: Content) -> some View {
        content
            .onAppear { sync() }
            .onChange(of: mode) { _ in sync() }
            .onDisappear { presenter.hide() }
            // 取不到订单时（冷启动恢复、网络慢）不阻塞警报：名字与电话缺省，其余信息照出。
            .task(id: coordinator.volunteerAlert?.orderID) {
                guard let orderID = coordinator.volunteerAlert?.orderID else {
                    presenter.peer = nil
                    return
                }
                // 拿不到就再试几次：警报上的「打电话」靠它，网络差时一次失败不能让按钮一直缺席。
                for attempt in 0..<3 {
                    if let detail = try? await appState.orders.orderDetail(orderId: orderID) {
                        presenter.peer = VolunteerEmergencyAlertPeer.make(from: detail)
                        return
                    }
                    if attempt < 2 { try? await Task.sleep(nanoseconds: 3_000_000_000) }
                    if Task.isCancelled { return }
                }
            }
    }

    private func sync() {
        // 求助结束就清掉「回看」标志：否则下一条已确认的告警会直接以整屏出现。
        if mode == .none { presenter.isReviewing = false }
        presenter.apply(mode, content: {
            AnyView(VolunteerEmergencyWindowContent(
                coordinator: coordinator,
                presenter: presenter,
                locationService: locationService,
                reverseGeocode: { await amapGeocodingService.reverseGeocode(coordinate: $0)?.title },
                serverAddress: { try? await appState.safety.orderLocationAddress(orderId: $0) },
                onAcknowledge: { eventID in Task { await acknowledge(eventID: eventID) } }
            ))
        })
    }

    private func acknowledge(eventID: Int64) async {
        guard !presenter.isAcknowledging else { return }
        presenter.isAcknowledging = true
        let succeeded = await coordinator.acknowledgeAsVolunteer(eventID: eventID, safety: appState.safety)
        presenter.isAcknowledging = false
        if succeeded {
            speechService.speak(EmergencySafetyCopy.volunteerAcknowledged)
        } else {
            speechService.speakError(Self.acknowledgeFailure)
        }
    }
}

/// 现在该显示哪一种。**纯函数**，用例 `VolunteerReceiveRunnerActionsTests`。
enum VolunteerEmergencyWindowMode: Equatable {
    case none, full, bar

    static func resolve(alert: VolunteerEmergencyAlert?, isReviewing: Bool) -> Self {
        guard let alert else { return .none }
        return (!alert.isAcknowledged || isReviewing) ? .full : .bar
    }
}

/// 管两个独立 window：整屏警报与顶部常驻条。
@MainActor
final class VolunteerEmergencyWindowPresenter: ObservableObject {
    @Published var isReviewing = false
    @Published var peer: VolunteerEmergencyAlertPeer?
    @Published var isAcknowledging = false

    private var window: UIWindow?
    private var shownMode: VolunteerEmergencyWindowMode = .none
    private var previousKeyWindow: UIWindow?

    private static let barHeight: CGFloat = 44
    private static let barWidth: CGFloat = 220
    /// 订单页自定义顶栏那一行的高度（返回 / 更多操作 / 求助都是 64pt 的按钮，`FlowOrderNavBar`）。
    /// 红条放在这一行下面：放进这一行会盖住「更多操作」（#1024 真机走查）。
    private static let topBarRowHeight: CGFloat = 64
    /// 顶栏按钮随字号变高，但有上限：AX-XXXL 真机实测最高的是陪跑员首页「设置」88pt（#1024）。取 96 留余量。
    private static let topBarRowMaxHeight: CGFloat = 96
    private static let barGapBelowTopBar: CGFloat = 4
    /// 左右各留的边距：最大字号时红条按字号放宽，但不贴屏幕边。
    private static let barSideMargin: CGFloat = 16

    func hide() {
        shownMode = .none
        tearDown()
    }

    func apply(_ mode: VolunteerEmergencyWindowMode, content: () -> AnyView) {
        guard mode != shownMode else { return }
        tearDown()
        shownMode = mode
        guard mode != .none,
              let scene = UIApplication.shared.connectedScenes.compactMap({ $0 as? UIWindowScene }).first(where: {
                  $0.activationState == .foregroundActive
              }) ?? UIApplication.shared.connectedScenes.compactMap({ $0 as? UIWindowScene }).first
        else { return }

        let host = UIHostingController(rootView: content())
        host.view.backgroundColor = .clear
        // 顶部常驻条的窗口不在屏幕顶上，宿主仍按整屏的安全区把内容往下推，真机上文字掉出窗口、红底拉到约 100pt（#1024 走查）。
        if #available(iOS 16.4, *) { host.safeAreaRegions = [] }
        let window = UIWindow(windowScene: scene)
        window.rootViewController = host
        window.windowLevel = .alert + 1
        if mode == .full {
            previousKeyWindow = scene.windows.first { $0.isKeyWindow }
            window.backgroundColor = UIColor(AppColors.background)
            window.makeKeyAndVisible()
        } else {
            // 只占顶栏下面正中一小块：全宽的条、或放进顶栏那一行，都会盖住返回 / 更多操作 / 求助，
            // 而求助期间陪跑员最需要的就是能退出、能操作。窗口只有这一块，其余触摸照常落到下面的页面。
            // 尺寸按字号放大（文字是 caption），否则最大字号时字被裁掉；创建时取一次。
            let top = scene.windows.first { $0 !== window }?.safeAreaInsets.top ?? 0
            let screenWidth = scene.coordinateSpace.bounds.width
            let metrics = UIFontMetrics(forTextStyle: .caption1)
            let width = min(metrics.scaledValue(for: Self.barWidth), screenWidth - 2 * Self.barSideMargin)
            let topBarRow = min(UIFontMetrics(forTextStyle: .body).scaledValue(for: Self.topBarRowHeight), Self.topBarRowMaxHeight)
            window.frame = CGRect(
                x: (screenWidth - width) / 2, y: top + topBarRow + Self.barGapBelowTopBar,
                width: width, height: metrics.scaledValue(for: Self.barHeight)
            )
            window.isHidden = false
        }
        self.window = window
    }

    private func tearDown() {
        window?.isHidden = true
        window = nil
        previousKeyWindow?.makeKey()
        previousKeyWindow = nil
    }
}

/// window 里的内容：整屏警报，或顶部常驻条。
struct VolunteerEmergencyWindowContent: View {
    @ObservedObject var coordinator: EmergencyCoordinator
    @ObservedObject var presenter: VolunteerEmergencyWindowPresenter
    @ObservedObject var locationService: LocationService
    let reverseGeocode: @MainActor (CLLocationCoordinate2D) async -> String?
    let serverAddress: @MainActor (Int64) async -> OrderLocationAddressResponse?
    let onAcknowledge: (Int64) -> Void

    var body: some View {
        if let alert = coordinator.volunteerAlert {
            if !alert.isAcknowledged || presenter.isReviewing {
                VolunteerEmergencyAlertView(
                    alert: alert,
                    peerName: presenter.peer?.name,
                    peerPhone: presenter.peer?.phone,
                    deviceCoordinate: locationService.currentLocation,
                    isAcknowledging: presenter.isAcknowledging,
                    // 已确认后再按这一枚只是回去，不再发第二次确认。
                    onAcknowledge: {
                        if alert.isAcknowledged { presenter.isReviewing = false } else { onAcknowledge(alert.eventID) }
                    },
                    reverseGeocode: { await reverseGeocode($0) },
                    serverAddress: { await serverAddress($0) }
                )
            } else {
                bar
            }
        }
    }

    private var bar: some View {
        Button { presenter.isReviewing = true } label: {
            HStack(spacing: 8) {
                Image(systemName: "exclamationmark.triangle.fill").accessibilityHidden(true)
                Text("求助中 · 回到警报")
                    .font(AppFonts.caption().weight(.bold))
                    .multilineTextAlignment(.center)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .foregroundColor(.white)
            .padding(.horizontal, 8)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(AppColors.destructive)
        }
        .buttonStyle(.plain)
        .accessibilityLabel("跑者的求助还没结束")
        .accessibilityHint("双击回到警报")
        .accessibilityIdentifier("volunteerEmergencyBar")
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
