import SwiftUI

// MARK: - Failure Announcement

/// 失败文案上屏的同时念出来（#527）。
///
/// 盲人端「屏幕上多了一行字」等于什么都没发生：只上屏不念，用户只会以为「点了没反应」，
/// 或者一直等一个永远不会来的结果。静态审查扫出四处这样的失败页（启动恢复失败、跑后路线加载失败、
/// 邀请码、固定搭档），后两处走的是共享的 `IncentiveFailureSection`，所以在那里接一次就全覆盖。
///
/// 挂在**只在失败时才渲染**的那块视图上：它出现时念一次，文案变了（重试又失败、原因不同）再念一次。
/// 走 `speakError`，带错误触感（`SpeechService.speakError` 的注释说了为什么错误要多一条通道）。
///
/// 等 `settleDelay` 再念：有的页面在第一次加载开始前会先渲染一帧失败态（志愿者培训页初始
/// `isLoading = false`），那一帧随即被「加载中」替换，`.task` 跟着取消，不会误报一句「加载失败」。
/// 真失败会一直留在屏幕上，照常念出来。
///
/// `attempt`：同一句失败文案、用户又重试了一次还是失败时，靠它再念一遍（#573）。不能只靠视图重建：
/// 断网时请求可能比一帧还快地失败，页面来不及先切走再切回来，同一句文案的 `.task` 就不会重跑 ——
/// 用户点了「重试」却听不到任何结果。
///
/// 🚩 **同一次失败只念一次。** `.task` 在视图每次重新出现时都会再跑（切回这个标签页、从推进去的页面返回），
/// 不记一下的话，停在失败态的卡片每回一次首页就念一遍、震一下 —— 陪跑员端语音默认关，
/// 用户只剩「每次回首页手机就震」（真机反馈 2026-11-26）。记的是视图状态：视图真被拆掉重建（离开整页再进来）
/// 算一次新的出现，照常念。
extension View {
    func announcesFailure(_ message: String, using speechService: SpeechService, attempt: Int = 0) -> some View {
        modifier(FailureAnnouncementModifier(
            key: FailureAnnouncement.Key(message: message, attempt: attempt),
            speechService: speechService
        ))
    }
}

private struct FailureAnnouncementModifier: ViewModifier {
    let key: FailureAnnouncement.Key
    let speechService: SpeechService
    /// 已经念过的那一次。念完才记：没等到 `settleDelay` 就被换掉的那一帧不算念过。
    @State private var announcedKey: FailureAnnouncement.Key?

    func body(content: Content) -> some View {
        content.task(id: key) {
            guard announcedKey != key else { return }
            try? await Task.sleep(nanoseconds: FailureAnnouncement.settleDelayNanoseconds)
            guard !Task.isCancelled else { return }
            announcedKey = key
            speechService.speakError(key.message)
        }
    }
}

enum FailureAnnouncement {
    struct Key: Equatable {
        let message: String
        let attempt: Int
    }

    /// 0.3 秒：比一次「失败态 → 加载中」的切换长，又短到用户察觉不到延迟。
    static let settleDelayNanoseconds: UInt64 = 300_000_000
}
