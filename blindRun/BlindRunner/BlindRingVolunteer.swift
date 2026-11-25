import Combine
import SwiftUI

// MARK: - 跑者让陪跑员的手机响（后端 #1046，iOS #1023）

/// `ring-runner` 的反方向：汇合时陪跑员到了却找不到跑者，反过来跑者也找不到陪跑员（全盲跑者没法靠眼睛找人）；
/// 陪跑中走散时同理。后端两个阶段各 20 次、两次之间隔 10 秒，`DRIVER_EN_ROUTE`（陪跑员还在路上）409。
enum BlindRingVolunteerCopy {
    static let title = "让陪跑员的手机响"
    static let ringingTitle = "陪跑员的手机正在响"

    static func detail(for status: RunOrderStatus) -> String {
        status == .inProgress ? "走散了找不到陪跑员时按" : "到了集合点却找不到陪跑员时按"
    }

    static let accessibilityHint = "双击后陪跑员的手机会响，他会出声回应，你可以循着声音找他"

    static let success = "陪跑员的手机正在响"
    /// 推送没发出去（`delivered == false`）。不是自己拼的限频文案，限频念后端 `message`。
    static let notDelivered = "对方可能没收到，请再按一次，或打电话给陪跑员。"
    static let failed = "没有发出去，请再按一次。"

    /// 这一单此刻能不能按。`DRIVER_EN_ROUTE` 后端 409，不显示按钮。
    static func isAvailable(in status: RunOrderStatus) -> Bool {
        status == .driverArrived || status == .inProgress
    }
}

/// 一次按下去的状态与结果。订单页持有一个，汇合页和跑步页共用：汇合变陪跑中时冷却不丢。
@MainActor
final class BlindRingVolunteerViewModel: ObservableObject {
    /// 后端下发的响铃截止时刻。**不自己加秒数**：之前按钮不可点，到点自动恢复。
    @Published private(set) var ringingUntil: Date?
    /// 屏幕上可见的结果一行（失败、限频、没送到）。成功时为 `nil`。
    @Published private(set) var notice: String?
    @Published private(set) var isSending = false

    func isRinging(at date: Date) -> Bool {
        (ringingUntil ?? .distantPast) > date
    }

    func ring(
        orderId: Int64,
        now: Date = Date(),
        send: (Int64) async throws -> OrderNudgeResponse,
        speak: (String) -> Void,
        speakError: (String) -> Void
    ) async {
        guard !isSending, !isRinging(at: now) else { return }
        isSending = true
        defer { isSending = false }
        do {
            let response = try await send(orderId)
            guard response.delivered != false else {
                // 推送没发出去，没有东西在响：不进冷却，让他能马上再按。
                notice = BlindRingVolunteerCopy.notDelivered
                speakError(BlindRingVolunteerCopy.notDelivered)
                return
            }
            ringingUntil = response.ringingUntil?.backendTimestamp
            notice = nil
            HapticFeedback.play(.tick)
            speak(BlindRingVolunteerCopy.success)
        } catch let error as APIError {
            if error.endsSession { return }
            let message: String
            if case .rateLimited(let info) = error {
                // 限频念后端给的 message，不自己拼（`localizedMessage` 会再接一句「请在N秒后重试」）。
                message = info.message
            } else {
                message = error.localizedMessage
            }
            notice = message
            speakError(message)
        } catch {
            notice = BlindRingVolunteerCopy.failed
            speakError(BlindRingVolunteerCopy.failed)
        }
    }
}

/// 汇合页抽屉与跑步页各放一张。按钮位置：汇合页在陪跑员行下面、「取消本单」上面；跑步页在彩色卡与行程分享之后。
struct BlindRingVolunteerRow: View {
    let orderId: Int64
    let status: RunOrderStatus

    @EnvironmentObject private var appState: AppState
    @EnvironmentObject private var speechService: SpeechService
    @StateObject private var model = BlindRingVolunteerViewModel()

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            // 每秒重算一次：到 `ringingUntil` 自己恢复可按，不靠别的刷新来唤醒。
            TimelineView(.periodic(from: .now, by: 1)) { context in
                button(isRinging: model.isRinging(at: context.date))
            }
            if let notice = model.notice {
                Text(notice)
                    .flowFont(FlowV2Fonts.callout(bold: true))
                    .foregroundColor(AppColors.Flow.primaryText)
                    .fixedSize(horizontal: false, vertical: true)
                    .accessibilityIdentifier("blindRingVolunteerNotice")
            }
        }
    }

    private func ringTapped() {
        let speech = speechService
        let orders = appState.orders
        Task {
            await model.ring(
                orderId: orderId,
                send: { try await orders.ringVolunteer(orderId: $0) },
                speak: { speech.speak($0) },
                speakError: { speech.speakError($0) }
            )
        }
    }

    private func button(isRinging: Bool) -> some View {
        let title = isRinging ? BlindRingVolunteerCopy.ringingTitle : BlindRingVolunteerCopy.title
        return Button(action: ringTapped) {
            BlindRunCardSurface {
                HStack(spacing: 14) {
                    Image(systemName: "bell.and.waves.left.and.right.fill")
                        .font(.system(size: 24))
                        .foregroundColor(AppColors.Flow.onBlueTint)
                        .accessibilityHidden(true)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(title)
                            .flowFont(FlowV2Fonts.headline())
                            .foregroundColor(AppColors.Flow.primaryText)
                            .fixedSize(horizontal: false, vertical: true)
                        Text(BlindRingVolunteerCopy.detail(for: status))
                            .flowFont(FlowV2Fonts.subhead())
                            .foregroundColor(AppColors.Flow.secondaryText)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    Spacer(minLength: 0)
                }
                .frame(minHeight: AppTouchTarget.blindPrimary)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        // `.disabled` 而不是在 action 里 `guard return`：读屏念「变暗」，静默 return 对读屏是一个正常按钮、双击后什么都不发生。
        .disabled(isRinging || model.isSending)
        .opacity(isRinging ? 0.6 : 1)
        .accessibilityElement(children: .ignore)
        .accessibilityAddTraits(.isButton)
        .accessibilityLabel(isRinging ? title : "\(title)。\(BlindRingVolunteerCopy.detail(for: status))")
        .accessibilityHint(isRinging ? "" : BlindRingVolunteerCopy.accessibilityHint)
        .accessibilityIdentifier("blindRingVolunteerButton")
    }
}
