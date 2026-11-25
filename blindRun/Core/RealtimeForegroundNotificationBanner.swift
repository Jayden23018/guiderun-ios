import Combine
import Foundation
import SwiftUI

struct RealtimeForegroundNotificationBanner: View {
    let notification: RealtimeForegroundNotification
    let onDismiss: () -> Void

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: notification.priority == .high ? "exclamationmark.triangle.fill" : "bell.fill")
                .foregroundColor(notification.priority == .high ? AppColors.destructive : AppColors.primary)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 4) {
                if let title = notification.title?.nilIfBlank {
                    Text(title).font(AppFonts.body().weight(.bold))
                }
                Text(notification.displayText).font(AppFonts.body())
            }
            Spacer(minLength: 8)
            // `TextButtonStyle` 自带 `maxWidth: .infinity`：不收住宽度会和上面的 Spacer 对半分这一行，把通知文字挤窄。
            Button(action: onDismiss) {
                Text("关闭").frame(minWidth: AppTouchTarget.blindPrimary)
            }
            .buttonStyle(TextButtonStyle(alignment: .center))
            .fixedSize(horizontal: true, vertical: false)
            .accessibilityHint("关闭当前通知并显示下一条通知")
        }
        .padding(16)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 16))
        .overlay {
            RoundedRectangle(cornerRadius: 16)
                .stroke(notification.priority == .high ? AppColors.destructive : AppColors.primary, lineWidth: 2)
        }
        .shadow(color: .black.opacity(0.2), radius: 12, y: 4)
        .accessibilityElement(children: .combine)
        .accessibilityLabel(notification.speechText)
        .accessibilityAddTraits(notification.priority == .high ? .isHeader : [])
        .accessibilityIdentifier("realtimeForegroundNotification")
    }
}

/// 前台通知横幅挂在根视图上的那一层。**用 `@ObservedObject` 自己持有协调器**（#1028）：
/// 协调器挂在 `AppState` 上，嵌套的 ObservableObject 不会经 `AppState` 重新发布。原来横幅直接写在 `ContentView` 里，
/// 出现时靠播报改动 `SpeechService` 顺带重画才看得见；点「关闭」或 5 秒到点变成 nil 时没有任何东西让它重画，
/// 订单页上横幅就一直挂着（真机：到点 12 秒后仍在，转一下屏才消失）。
struct RealtimeForegroundNotificationOverlay: View {
    @ObservedObject var coordinator: AppRealtimeCoordinator
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        if let notification = coordinator.currentNotification {
            RealtimeForegroundNotificationBanner(
                notification: notification,
                onDismiss: { coordinator.dismissCurrentNotification() }
            )
            .padding(.horizontal, 16)
            .padding(.top, 8)
            // 「减弱动态效果」开启时只淡入淡出，不从屏幕顶端滑进来。
            // 这条横幅是主动弹出的（不是用户操作触发），突然的位移最容易引起不适；
            // 淡入保留了「有新东西出现」这个提示本身。
            .transition(reduceMotion ? .opacity : .move(edge: .top).combined(with: .opacity))
            .zIndex(100)
        }
    }
}
