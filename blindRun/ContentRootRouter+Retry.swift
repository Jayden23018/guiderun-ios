import Foundation
import SwiftUI

/// 回到前台时调 `retryRecoveryIfFailed`。挂在 `ContentView` 根上（单独一个 modifier：
/// `ContentView` 的文件长度被 SwiftLint 闸冻结，只许变小）。
struct RecoveryRetryOnForeground: ViewModifier {
    let router: ContentRootRouter
    @EnvironmentObject private var appState: AppState
    @Environment(\.scenePhase) private var scenePhase

    func body(content: Content) -> some View {
        content.onChange(of: scenePhase) { phase in
            guard phase == .active else { return }
            Task { await router.retryRecoveryIfFailed(with: appState) }
        }
    }
}

extension ContentRootRouter {
    /// 启动恢复失败页的「重试恢复」（#573）。
    ///
    /// 恢复失败有两种来路，重试要做的事不一样：
    /// - **会话校验失败**（`.validationFailed`，`/api/auth/me` 断网或 5xx）：要重新校验会话。
    ///   原来按钮只调 `synchronize`，它按**现有**状态重选页面，不发任何请求，`restoreSession()` 全 App
    ///   只在启动时调一次 ⇒ 网络恢复后点了也原样不动，盲人只能杀进程。
    /// - **资料加载失败**（会话已确认，hydrate 失败）：`synchronize` 本身就会重新拉资料，照旧。
    ///
    /// 结果的反馈：成功走正常路由；又失败时 `failedRecoveryRetries` 加一，失败页靠它把原因再念一遍
    ///（`announcesFailure(attempt:)` 的注释说了为什么不能只靠页面重建）。
    func retryRecovery(with appState: AppState) async {
        switch appState.sessionRestorationState {
        case .restoring:
            return // 上一次重试还没回来：连点不叠请求
        case .validationFailed:
            await appState.restoreSession()
            if case .validationFailed = appState.sessionRestorationState { failedRecoveryRetries += 1 }
        case .unauthenticated, .choosingRole, .authenticated:
            synchronize(with: appState)
        }
    }

    /// 回到前台时调：停在恢复失败页就先自己重试一次，不等人点（2026-11-26 负责人定）。
    /// 多半是切到后台时断了网，回来时网已经好了。别的页面什么都不做。
    func retryRecoveryIfFailed(with appState: AppState) async {
        guard case .recoveryFailed = route else { return }
        await retryRecovery(with: appState)
    }
}
