import AudioToolbox
import AVFoundation
import Combine
import OSLog
import SwiftUI
import UIKit

// MARK: - 陪跑员让跑者的手机响起来（`RUNNER_RING`）

/// 视障跑者没法主动找人，但能被声音找到：陪跑员在出发点按「让 TA 的手机响起来」，
/// 后端推 `APP_NOTIFICATION`（`eventType=RUNNER_RING`），信封多带一个 `until`
/// （`websocket-protocol.md` §2.2 / `api_spec.yaml` `ring-runner`）。
/// 跑者这边：先念一句，再循环响铃到 `until`，任意操作即停。
///
/// 陪跑中走散时陪跑员按同一个接口，后端改推 `RUNNER_RING_LOST`（#445）。两者行为完全一致，
/// **只有话不同**：跑步中听到「陪跑员到了」是错的（契约原话：两句话不能混用）。
enum RunnerRingCopy {
    static let fallbackSpeech = "你的陪跑员到了，正在找你"
    static let title = "你的陪跑员到了"
    static let detail = "手机正在响，陪跑员会循着声音找到你。"
    static let accessibilityLabel = "你的陪跑员到了，手机正在响。停止响铃"

    static let lostFallbackSpeech = "你的陪跑员在找你，请原地停下"
    static let lostTitle = "请原地停下"
    static let lostDetail = "你的陪跑员在找你。手机正在响，陪跑员会循着声音找到你。"
    static let lostAccessibilityLabel = "你的陪跑员在找你，请原地停下。手机正在响。停止响铃"

    static let stopTitle = "停止响铃"
    static let accessibilityHint = "双击屏幕任意位置停止响铃"

    // 反方向（#1023）：跑者让陪跑员的手机响。两句话不能混用：跑步中说「在出发点」是错的。
    static let seekingFallbackSpeech = "跑者在找你，请出声回应"
    static let seekingTitle = "跑者在找你"
    static let seekingDetail = "手机正在响。请出声回应，让跑者循着声音找到你。"
    static let seekingAccessibilityLabel = "跑者在找你，请出声回应。手机正在响。知道了，停止响铃"

    static let runnerLostFallbackSpeech = "跑者找不到你，请原地出声回应"
    static let runnerLostTitle = "跑者找不到你"
    static let runnerLostDetail = "手机正在响。请原地出声回应，不要走开，让跑者找到你。"
    static let runnerLostAccessibilityLabel = "跑者找不到你，请原地出声回应。手机正在响。知道了，停止响铃"

    static let volunteerStopTitle = "知道了"
    static let volunteerAccessibilityHint = "双击屏幕任意位置，知道了并停止响铃"

    static func fallbackSpeech(_ kind: RunnerRingRequest.Kind) -> String {
        switch kind {
        case .arrived: return fallbackSpeech
        case .lost: return lostFallbackSpeech
        case .runnerSeeking: return seekingFallbackSpeech
        case .runnerLost: return runnerLostFallbackSpeech
        }
    }

    static func title(_ kind: RunnerRingRequest.Kind) -> String {
        switch kind {
        case .arrived: return title
        case .lost: return lostTitle
        case .runnerSeeking: return seekingTitle
        case .runnerLost: return runnerLostTitle
        }
    }

    static func detail(_ kind: RunnerRingRequest.Kind) -> String {
        switch kind {
        case .arrived: return detail
        case .lost: return lostDetail
        case .runnerSeeking: return seekingDetail
        case .runnerLost: return runnerLostDetail
        }
    }

    static func accessibilityLabel(_ kind: RunnerRingRequest.Kind) -> String {
        switch kind {
        case .arrived: return accessibilityLabel
        case .lost: return lostAccessibilityLabel
        case .runnerSeeking: return seekingAccessibilityLabel
        case .runnerLost: return runnerLostAccessibilityLabel
        }
    }

    /// 停止按钮的字。跑者端是「停止响铃」，陪跑员端按设计是「知道了」。
    static func stopTitle(_ kind: RunnerRingRequest.Kind) -> String {
        kind.isForVolunteer ? volunteerStopTitle : stopTitle
    }

    static func accessibilityHint(_ kind: RunnerRingRequest.Kind) -> String {
        kind.isForVolunteer ? volunteerAccessibilityHint : accessibilityHint
    }
}

/// 一次响铃。只由 `make(from:receivedAt:)` 产生 —— 能不能响的判据全在那里。
struct RunnerRingRequest: Equatable, Sendable {
    /// 哪一种找人。只由 eventType 决定，正文改字不影响分支。
    enum Kind: Equatable, Sendable {
        /// 汇合期，`RUNNER_RING`。
        case arrived
        /// 陪跑中走散，`RUNNER_RING_LOST`。
        case lost
        /// 反方向，陪跑员端：汇合期跑者在找你，`VOLUNTEER_RING`（#1023）。
        case runnerSeeking
        /// 反方向，陪跑员端：陪跑中跑者找不到你，`VOLUNTEER_RING_LOST`。
        case runnerLost

        /// `nil` = 不是响铃事件。
        init?(eventType: String) {
            switch eventType.uppercased() {
            case "RUNNER_RING": self = .arrived
            case "RUNNER_RING_LOST": self = .lost
            case "VOLUNTEER_RING": self = .runnerSeeking
            case "VOLUNTEER_RING_LOST": self = .runnerLost
            default: return nil
            }
        }

        /// 响的是陪跑员的手机。协调器按它分角色：陪跑员端只收这两种，跑者端只收另两种。
        var isForVolunteer: Bool { self == .runnerSeeking || self == .runnerLost }
    }

    let id: String
    let orderId: Int64?
    let speechText: String
    let endsAt: Date
    var kind: Kind = .arrived

    /// 响铃时长上限。后端是「受理 + 10 秒」，这里只防异常值把手机响上几分钟。
    static let maximumDuration: TimeInterval = 30

    /// `nil` = 这一条不该响（缺 `until`、解析不出、或已经过了），调用方按普通通知念一次。
    ///
    /// 时长优先用 `until − timestamp`：两者都是**服务端时钟**，本机时钟偏几秒不影响。
    /// 差值不在 `(0, 60]` 里（`timestamp` 缺失、带了别的时区）才退回 `until − 本机 now`。
    static func make(from message: WSAppNotification, receivedAt: Date) -> RunnerRingRequest? {
        guard let kind = Kind(eventType: message.eventType),
              let rawUntil = message.until?.nilIfBlank,
              let until = rawUntil.backendTimestamp else { return nil }
        var duration = message.timestamp?.backendTimestamp.map { until.timeIntervalSince($0) } ?? -1
        if duration <= 0 || duration > 60 {
            duration = until.timeIntervalSince(receivedAt)
        }
        duration = min(duration, maximumDuration)
        guard duration > 0 else { return nil }
        let text = message.ttsText?.nilIfBlank ?? message.body.nilIfBlank ?? RunnerRingCopy.fallbackSpeech(kind)
        return RunnerRingRequest(
            id: message.messageId?.nilIfBlank ?? "\(message.orderId ?? 0)-\(rawUntil)",
            orderId: message.orderId,
            // 外放朗读，掩码姓名里的星号不许念出来（`unmaskedForSpeech`）。
            speechText: text.unmaskedForSpeech,
            endsAt: receivedAt.addingTimeInterval(duration),
            kind: kind
        )
    }
}

// MARK: - 提示音

/// 响铃用的提示音：下行「叮咚」+ 静音，1 秒一循环。
///
/// 频率避开全 App 已用的各组（录音起止、播报引导、倒计时、求助警报）——
/// 求助警报 740/988 尤其不能复用：「陪跑员到了」听成「有人求救」是事故。
/// 做法照抄 `EmergencyAlarm`：`ToneSynthesizer` 合成、`.playback` 分类下静音拨杆照响、
/// 播放器**创建后常驻不释放**（`finishedPlaying:` 崩溃的教训）。
@MainActor
enum RunnerRingTone {
    /// `0` = 静音段。
    static let frequencies: [Double] = [1568, 1244.5, 0, 0]
    static let segmentDuration: TimeInterval = 0.25

    private static var player: AVAudioPlayer?
    private static let logger = Logger(subsystem: Bundle.main.bundleIdentifier ?? "AidRun", category: "RunnerRing")

    #if DEBUG
    /// 测试接缝：设了就接管发声，`true` = 开始，`false` = 停止。
    static var observerForTesting: ((Bool) -> Void)?
    #endif

    static func start() {
        #if DEBUG
        if let observerForTesting { observerForTesting(true); return }
        #endif
        do {
            let player = try player ?? makePlayer()
            player.numberOfLoops = -1
            player.currentTime = 0
            player.play()
        } catch {
            // 响不出来不该让页面跟着出错，朗读那一句已经念过了。
            logger.error("响铃播放失败：\(error.localizedDescription, privacy: .public)")
        }
    }

    static func stop() {
        #if DEBUG
        if let observerForTesting { observerForTesting(false); return }
        #endif
        player?.stop()
    }

    private static func makePlayer() throws -> AVAudioPlayer {
        let created = try AVAudioPlayer(
            data: ToneSynthesizer.wav(frequencies: frequencies, segmentDuration: segmentDuration)
        )
        // App 能给的最大音量。系统音量没有公开 API 可改，这里不去碰。
        created.volume = 1
        created.prepareToPlay()
        player = created
        return created
    }
}

// MARK: - 起止控制

/// 一次响铃的生命周期：念 → 等念完（有上限）→ 循环响 → 到 `endsAt` 或被按停。
@MainActor
final class RunnerRingController: ObservableObject {
    @Published private(set) var active: RunnerRingRequest?

    /// 先念后响的等待上限。同时起的话铃声会盖住那句「你的陪跑员到了」。
    static let speechWaitLimit: TimeInterval = 4
    /// 陪跑员端两次震动的间隔，与提示音「1 秒一循环」同拍。
    static let vibrationInterval: TimeInterval = 1

    var speak: (String) -> Void = { _ in }
    var isSpeaking: () -> Bool = { false }
    var startTone: () -> Void = { RunnerRingTone.start() }
    var stopTone: () -> Void = { RunnerRingTone.stop() }
    /// 陪跑员端（`Kind.isForVolunteer`）响铃时每秒震一下，跑者端不震（现有行为不动）。
    var vibrate: () -> Void = { AudioServicesPlaySystemSound(kSystemSoundID_Vibrate) }
    /// 响完或被按停之后。用来清掉协调器上那一条，免得重新订阅时回放。
    var onFinish: () -> Void = {}

    private let now: () -> Date
    private var handledIDs: Set<String> = []
    private var task: Task<Void, Never>?

    init(now: @escaping () -> Date = Date.init) {
        self.now = now
    }

    /// `@Published` 重新订阅会回放当前值，所以这里自己挡：处理过的 id、已经过点的，都不再响。
    func handle(_ ring: RunnerRingRequest?) {
        guard let ring, !handledIDs.contains(ring.id), ring.endsAt > now() else { return }
        handledIDs.insert(ring.id)
        task?.cancel()
        stopTone()
        active = ring
        task = Task { [weak self] in await self?.run(ring) }
    }

    /// 任意操作即停。
    func stop() {
        guard active != nil else { return }
        finish()
    }

    private func run(_ ring: RunnerRingRequest) async {
        speak(ring.speechText)
        let toneDeadline = min(ring.endsAt, now().addingTimeInterval(Self.speechWaitLimit))
        while isSpeaking(), now() < toneDeadline {
            try? await Task.sleep(nanoseconds: 100_000_000)
            if Task.isCancelled { return }
        }
        if Task.isCancelled { return }
        let remaining = ring.endsAt.timeIntervalSince(now())
        if remaining > 0 {
            startTone()
            if ring.kind.isForVolunteer {
                while now() < ring.endsAt {
                    vibrate()
                    let step = min(Self.vibrationInterval, ring.endsAt.timeIntervalSince(now()))
                    try? await Task.sleep(nanoseconds: UInt64(max(step, 0) * 1_000_000_000))
                    if Task.isCancelled { return }
                }
            } else {
                try? await Task.sleep(nanoseconds: UInt64(remaining * 1_000_000_000))
                if Task.isCancelled { return }
            }
        }
        finish()
    }

    private func finish() {
        task?.cancel()
        task = nil
        stopTone()
        active = nil
        onFinish()
    }
}

// MARK: - 遮罩

/// 响铃期间盖住整屏。点任意位置、VoiceOver 双击、magic tap、返回手势都停。
///
/// 🔴 magic tap 必须挂在这一层：`BlindRunnerTabView` 的 TabView 上 magic tap = 求助，
/// 这里不接住的话，读屏用户想停铃会弹出求助确认。
struct RunnerRingOverlay: View {
    let kind: RunnerRingRequest.Kind
    let onStop: () -> Void

    var body: some View {
        ScrollView {
            VStack(spacing: 24) {
                Image(systemName: "bell.and.waves.left.and.right.fill")
                    .font(.system(size: 56))
                    .foregroundColor(AppColors.primary)
                Text(RunnerRingCopy.title(kind))
                    .font(AppFonts.largeTitle())
                    .foregroundColor(AppColors.textPrimary)
                    .multilineTextAlignment(.center)
                    .fixedSize(horizontal: false, vertical: true)
                Text(RunnerRingCopy.detail(kind))
                    .font(AppFonts.body())
                    .foregroundColor(AppColors.textSecondary)
                    .multilineTextAlignment(.center)
                    .fixedSize(horizontal: false, vertical: true)
                PrimaryButton(RunnerRingCopy.stopTitle(kind), action: onStop)
            }
            .readableContentColumn()
            .padding(24)
            .padding(.top, 48)
            .frame(maxWidth: .infinity)
        }
        .background(AppColors.background.ignoresSafeArea())
        .contentShape(Rectangle())
        .onTapGesture(perform: onStop)
        // 整屏一个元素：读屏焦点落在哪都能双击停。
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(RunnerRingCopy.accessibilityLabel(kind))
        .accessibilityHint(RunnerRingCopy.accessibilityHint(kind))
        .accessibilityAddTraits(.isButton)
        .accessibilityAction(.default, onStop)
        .accessibilityAction(.magicTap, onStop)
        .accessibilityAction(.escape, onStop)
        .accessibilityIdentifier("runnerRingOverlay")
        .onAppear { UIAccessibility.post(notification: .screenChanged, argument: nil) }
    }
}

// MARK: - 推送与 WebSocket 不响两遍

/// `VOLUNTEER_RING` / `VOLUNTEER_RING_LOST` 每次都同时发 WS 和 APNs（后端 #1046）。App 在前台时 WS 那一条已经出声、
/// 震动、念了一句，推送再出横幅、提示音、朗读就是第二遍，所以前台一律不呈现推送；点开推送（响铃多半早过点了）也不补念。
/// App 在后台时系统自己出横幅和提示音（`time-sensitive`），不经过这里。
///
/// 🔴 **只在 WS 连着时才吞。** WS 掉线或重连中，推送是这一次唯一的通道（推送里没有 `until`，起不了完整的响铃），
/// 吞掉它跑者拿到「正在响」而陪跑员什么都听不到。这时照常出横幅、提示音并朗读。
///
/// 不比对 `recipientUserId`：这两种推送在 App 里**从不**朗读或上屏，换人登录后念给下一个人的风险不存在。
enum VolunteerRingPush {
    static func isRingEvent(_ userInfo: [AnyHashable: Any]) -> Bool {
        (userInfo["eventType"] as? String).flatMap(RunnerRingRequest.Kind.init(eventType:))?.isForVolunteer == true
    }

    /// 前台收到这条推送时是否整条不呈现：响铃事件，且 WS 此刻连着（那一条已经在响）。
    static func suppressesForeground(_ userInfo: [AnyHashable: Any], isWebSocketConnected: Bool) -> Bool {
        isWebSocketConnected && isRingEvent(userInfo)
    }
}
