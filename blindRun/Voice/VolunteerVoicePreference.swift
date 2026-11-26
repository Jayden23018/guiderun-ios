import SwiftUI

// 陪跑员端的 App 自带语音默认关，「我的」里可以打开（backend#1064：陪跑员反馈播报扰人）。盲人端不读这个开关。
//
// 关着时 `VoiceService.speak` 只发 VoiceOver 通告、不出合成语音。照念的有两类：
// 警示与紧急求助档（`priority >= .alert`），以及调用点标了 `essential: true` 的
// 求助 / 走散 / 跑者响铃、用户自己点的朗读和他自己打开的每公里播报。
// 提示音、震动、推送声音不归这里管。
// 🔴 陪跑员端新增安全类播报时要标 `essential: true`，否则默认是静音的。

enum VolunteerVoicePreference {
    static let defaultsKey = "volunteerAppVoiceEnabled"
    static let toggleTitle = "App 语音播报"
    static let toggleSubtitle = "关着时仍念安全提醒和跑者找你的响铃，点按朗读和公里播报照常；提示音和 VoiceOver 不受影响"

    /// 角色未定（登录页、选角色页）和盲人端一律照念：那两处盲人用户靠它操作。
    static func silencesRoutineSpeech(role: UserRole?, defaults: UserDefaults = .standard) -> Bool {
        role == .volunteer && !defaults.bool(forKey: defaultsKey)
    }
}

extension VoiceService {
    /// 每次发声现读角色与开关，所以切换角色、拨开关都立即生效。
    @MainActor
    func followVolunteerVoicePreference(of appState: AppState, defaults: UserDefaults = .standard) {
        isRoutineSpeechSilenced = { [weak appState] in
            // `speak` 的调用点线程不定（见 `VoiceService.queue`）。不在主线程时读持久化会碰到隔离状态，照念。
            guard Thread.isMainThread else { return false }
            return MainActor.assumeIsolated {
                VolunteerVoicePreference.silencesRoutineSpeech(role: appState?.activeRole, defaults: defaults)
            }
        }
    }
}

/// 挂在根视图上，把开关接到唯一的那个 `VoiceService`。
struct VolunteerVoiceGate: ViewModifier {
    @EnvironmentObject private var appState: AppState
    @EnvironmentObject private var speechService: SpeechService

    func body(content: Content) -> some View {
        content.onAppear { speechService.followVolunteerVoicePreference(of: appState) }
    }
}

/// 陪跑员「我的」里的开关行。
struct VolunteerAppVoiceRow: View {
    @AppStorage(VolunteerVoicePreference.defaultsKey) private var isOn = false

    var body: some View {
        Toggle(isOn: $isOn) {
            VStack(alignment: .leading, spacing: 2) {
                Text(VolunteerVoicePreference.toggleTitle)
                    .flowFont(FlowV2Fonts.callout(bold: true))
                    .foregroundColor(AppColors.Flow.primaryText)
                Text(VolunteerVoicePreference.toggleSubtitle)
                    .flowFont((13, .regular, .footnote))
                    .foregroundColor(AppColors.Flow.secondaryText)
            }
            .fixedSize(horizontal: false, vertical: true)
        }
        .padding(.horizontal, GroupedCardMetrics.rowHorizontalPadding)
        .padding(.vertical, 12)
        .frame(maxWidth: .infinity, minHeight: GroupedCardMetrics.rowMinHeight, alignment: .leading)
        .accessibilityIdentifier("volunteerAppVoiceToggle")
    }
}

extension AppRealtimeCoordinator {
    /// 安全档之外、陪跑员关了语音也要念的事件：超时未结束（跑者可能失联）、跑者发的节奏信号
    /// （「稍慢一点」）、跑者手机快没电。
    private static let volunteerSafetyEventTypes: Set<String> = ["ORDER_OVERDUE", "RUN_RHYTHM", "RUNNER_BATTERY_LOW"]

    /// 这个事件类型的通知，陪跑员关了语音也要念。
    ///
    /// 没有类型的照念：后端给陪跑员求助告警落库时不写 `eventType`，重连补读认不出来。宁可多念。
    static func keepsVolunteerSpeech(forEventType eventType: String) -> Bool {
        let type = eventType.uppercased()
        return type.isEmpty
            || volunteerSafetyEventTypes.contains(type)
            || isSafetyEventType(type)
            || type.hasPrefix("EMERGENCY_")
            || type.hasPrefix("ESCORT_")
            || RunnerRingRequest.Kind(eventType: type)?.isForVolunteer == true
    }
}

extension LiveEscortHealthState {
    /// 同行位置共享出了问题（走散检测跟着失效），属于安全提醒。正常开启的两句不算。
    var isDegraded: Bool {
        switch self {
        case .idle, .active, .trackConsentRequired: return false
        case .waitingForLocation, .permissionRequired, .preciseLocationOff,
             .networkDisconnected, .locationSharingDeclined: return true
        }
    }
}
