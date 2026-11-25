import SwiftUI

// 陪跑员通话页的「不合适」「未接到来电」：收在顶栏「···」里，按下先确认（#660 V-9）。
// 负责人 2026-11-25 定：底部只留一枚主按钮，这两项与举报 / 不再匹配此人一起收进「···」，同盲人端
// （稿 `docs/ui/mockups/volunteer-intro-call-actions-20261125/`）。
// 单放一个文件：`VolunteerIntroCallView.swift` 已超长，SwiftLint 棘轮只许它变短。
// 两项仍是**两个端点**，不能合并（`VolunteerIntroCallViewModel.reportUnreachable` 的注释：统计口径相反）。

enum VolunteerIntroCallMenu {
    /// 「···」里这次沟通的两项。
    /// - `unreachableFirstSeen`: `nil` = 这一态不给「未接到来电」（③ 已提交 = 电话通了；本轮已结束）。
    ///   有值时进页满 `volunteerUnreachableDelayMinutes` 分钟才可点，之前灰着并写明何时可用。
    static func items(
        offersDecline: Bool,
        unreachableFirstSeen: Date?,
        now: Date,
        isSubmitting: Bool,
        decline: @escaping () -> Void,
        unreachable: @escaping () -> Void
    ) -> [VolunteerOrderMenuItem] {
        var items: [VolunteerOrderMenuItem] = []
        if offersDecline {
            items.append(VolunteerOrderMenuItem(
                kind: .introCallDecline,
                title: IntroCallCopy.volunteerDeclineButtonTitle,
                isEnabled: !isSubmitting,
                action: decline
            ))
        }
        if let unreachableFirstSeen {
            let available = VolunteerIntroCallUnreachableGate.isAvailable(firstSeenAt: unreachableFirstSeen, now: now)
            items.append(VolunteerOrderMenuItem(
                kind: .introCallUnreachable,
                title: IntroCallCopy.volunteerUnreachableButtonTitle,
                subtitle: available ? nil : IntroCallCopy.volunteerUnreachablePendingNotice,
                isEnabled: available && !isSubmitting,
                action: unreachable
            ))
        }
        return items
    }
}

extension View {
    /// 「不合适」「未接到来电」的确认框。开关在页面上，菜单项只翻开关。
    func volunteerIntroCallExitPrompts(
        viewModel: VolunteerIntroCallViewModel,
        confirmsDecline: Binding<Bool>,
        confirmsUnreachable: Binding<Bool>
    ) -> some View {
        self
            .alert(IntroCallCopy.volunteerDeclineConfirmTitle, isPresented: confirmsDecline) {
                Button(IntroCallCopy.declineConfirmCancelButton, role: .cancel) {}
                Button(IntroCallCopy.volunteerDeclineConfirmButton) {
                    Task { await viewModel.submit(.decline) }
                }
            } message: {
                Text(IntroCallCopy.volunteerDeclineConfirmMessage)
            }
            .alert(IntroCallCopy.volunteerUnreachableConfirmTitle, isPresented: confirmsUnreachable) {
                Button(IntroCallCopy.declineConfirmCancelButton, role: .cancel) {}
                Button(IntroCallCopy.volunteerUnreachableConfirmButton) {
                    Task { await viewModel.reportUnreachable() }
                }
            } message: {
                Text(IntroCallCopy.volunteerUnreachableConfirmMessage)
            }
    }
}
