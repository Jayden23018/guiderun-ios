import SwiftUI

/// 跑步页标题下第一张卡：陪跑员请求结束，请跑者确认自己在安全的地方（后端 #902，iOS #1016）。
///
/// 只在 `OrderDetailResponse.isAwaitingBlindSafetyConfirmation` 时出现；请求作废（`finishRequestedAt` 回到 null）就消失。
/// 跑者此刻多半手机在臂包里、刚跑完很累：卡片出现时把读屏焦点直接移到按钮上，不让他从顶栏一格格滑下来。
/// 实时推送那一句由全局安全横幅念（`FINISH_SAFETY_CONFIRM_REQUESTED`），这里不再另念。
///
/// 纵向排：说明 → 按钮。后续「还没到，继续陪我」作为第二个按钮加在确认按钮下面（后端还没有接口）。
struct BlindFinishSafetyCard: View {
    let isConfirming: Bool
    let onConfirm: () -> Void

    @AccessibilityFocusState private var isButtonFocused: Bool

    /// 等横幅那一句先开个头再移焦点：同一拍移过去，读屏念按钮会和横幅朗读叠在一起起头。
    static let focusDelayNanoseconds: UInt64 = 600_000_000

    var body: some View {
        BlindRunCardSurface(insets: EdgeInsets(top: 18, leading: 18, bottom: 18, trailing: 18)) {
            VStack(alignment: .leading, spacing: 12) {
                Text(FinishSafetyCopy.blindCardTitle)
                    .flowFont(FlowFonts.rowValueEmphasized())
                    .foregroundColor(AppColors.Flow.primaryText)
                    .accessibilityAddTraits(.isHeader)
                Text(FinishSafetyCopy.blindCardBody)
                    .flowFont(FlowFonts.rowValue())
                    .foregroundColor(AppColors.Flow.primaryText)
                    .fixedSize(horizontal: false, vertical: true)
                BlindOrderStageButton(
                    title: isConfirming ? FinishSafetyCopy.blindConfirmingButton : FinishSafetyCopy.blindConfirmButton,
                    systemImage: "checkmark.shield.fill",
                    style: .solid,
                    isEnabled: !isConfirming,
                    isLoading: isConfirming,
                    accessibilityHint: "确认后本次陪跑结束",
                    action: onConfirm
                )
                .accessibilityFocused($isButtonFocused)
                .accessibilityIdentifier("blindFinishSafetyConfirmButton")
            }
        }
        .accessibilityIdentifier("blindFinishSafetyCard")
        .task {
            try? await Task.sleep(nanoseconds: Self.focusDelayNanoseconds)
            isButtonFocused = true
        }
    }
}
