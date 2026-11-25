import Combine
import SwiftUI

/// 志愿者侧通话磨合页。
///
/// 数据来源是**派单载荷 + 通话端点**，不是订单详情：通话期 `order.volunteer` 恒为 null，
/// `GET /api/orders/{id}` 会 403（见 `VolunteerHomeViewModel.pendingIntroCallOrder`）。
///
/// 🔄 2026-10-15 按见面安排单视觉稿 v2 重做（`docs/ui/mockups/intro-call-meetup-plan-20261015/`，#433）：
/// - V1 等来电：主按钮「填写见面安排」（v6 是「合适，接这一单」）；「不合适」「未接到来电」在顶栏「···」（2026-11-25）
/// - V1′ 跑者正在来电：收到 `INTRO_CALL_INCOMING` 后 2 分钟，标题换句话、播一次
/// - V2 填写见面安排：`VolunteerMeetupPlanFormView`（表单页）
/// - V3 等跑者确认：安排摘要；「修改见面安排」（先提示需跑者重新确认）；「不合适」在「···」。**不显示跑者听没听、同不同意**
/// - V4 约好：原地变成订单页「约好」（新增见面位置与两人上衣，见 `VolunteerOrderFlowPresentation.meetupRows`）
/// - V4′ 没约成：「本次沟通已结束」+「返回首页」，**不自动跳转**（v6 停 3 秒自动关页，会截断播报）
/// 头卡整步沿用匹配钢蓝 `stateMatching`，去掉 v6 的通话前紫与通话后梅红；子状态靠那句话与绳子上的图标区分。
struct VolunteerIntroCallView: View {
    @EnvironmentObject private var appState: AppState
    @EnvironmentObject private var speechService: SpeechService
    @EnvironmentObject private var amapGeocodingService: AMapGeocodingService
    @Environment(\.dismiss) private var dismiss
    @StateObject private var viewModel = VolunteerIntroCallViewModel()
    /// 求助胶囊按下去：这一态不是 `IN_PROGRESS`，一律本地拨号（`VolunteerOrderSOSMode`）。
    @State private var showsLocalHelp = false
    @State private var showsPlanForm = false
    @State private var showsEditConfirm = false
    @State private var confirmsDecline = false
    @State private var confirmsUnreachable = false
    /// 举报 / 不再匹配此人收在顶栏「···」，弹层挂在页面上，两处共用这一份开关（2026-11-25）。
    @StateObject private var counterpartSafety = CounterpartBlockViewModel()
    @AccessibilityFocusState private var headerFocused: Bool
    /// 跑者确认那一刻（#962 第 6 项）：开了「减弱动态效果」就只做 0.25 秒淡入淡出。
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.scenePhase) private var scenePhase

    let route: VolunteerIntroCallRoute

    /// 派单载荷。冷启动恢复路径上是 nil —— 那两块信息没有数据源，见 `VolunteerIntroCallRoute`。
    private var dispatchOrder: WSNewOrder? { route.dispatchOrder }

    /// 倒计时胶囊与「正在来电」两分钟的刷新粒度。只换屏幕上的字，播报由 view model 在轮询里判。
    private static let clockTick: TimeInterval = 15

    var body: some View {
        Group {
            // 跑者确认那一刻（#962 第 6 项）：前 0.3 秒还留在 ③（圆点打勾），揭开后才换成 ④。
            if viewModel.outcome == .matched, let order = viewModel.matchedOrder, viewModel.matchedTransition?.revealed != false {
                // 成单：原地换成订单页（「约好」）。不 push：push 要一个 `isPresented` 绑定，
                // 返回时会被立刻重新推回去；原地换内容没有这个问题，订单页自己的返回键关掉的是整页。
                VolunteerInServiceView(orderId: order.orderId, initialOrder: order)
                    // 刚揭开：竖线往下长到「等出发」、当前行与底部按钮从下方淡入（盲人端 #926 同一套）。
                    .environment(\.blindOrderStageArrival, viewModel.matchedTransition?.revealed == true && !reduceMotion)
                    .transition(.opacity)
            } else {
                callPage
                    // 过渡的前 0.3 秒这一轮已经结束，旧 ③ 上的按钮不许再点。
                    .allowsHitTesting(viewModel.matchedTransition == nil)
                    .transition(.opacity)
            }
        }
        // 不放过渡时（减弱动态效果之外：人没一直看着 ③、或这轮没约成）仍是原来的 0.25 秒淡入淡出。
        .animation(.easeInOut(duration: BlindMatchFoundTiming.crossfade), value: viewModel.outcome)
        .task(id: viewModel.matchedTransition?.id) {
            await playMatchedTransition()
        }
        .onChange(of: scenePhase) { phase in
            viewModel.noteScenePhase(phase)
        }
        // 订单页那一族不带标签栏（设计交付 v3 §4.2 总表，S5 邀请就是 S6 的一个状态）；
        // 自带导航栏，系统那条整条藏掉，否则两条叠着。返回箭头在，不会把人关在这一页里。
        .toolbar(.hidden, for: .navigationBar)
        .toolbar(.hidden, for: .tabBar)
        .onAppear {
            viewModel.configure(
                orderId: route.orderId,
                appState: appState,
                speechService: speechService
            )
            viewModel.startPolling()
            appState.realtimeCoordinator.introCallPageDidAppear()
        }
        .onDisappear {
            viewModel.stopPolling()
            appState.realtimeCoordinator.introCallPageDidDisappear()
        }
        .onReceive(appState.realtimeCoordinator.introCallIncomingPublisher) { sentAt in
            viewModel.noteIncomingCall(sentAt: sentAt)
        }
        .onChange(of: viewModel.outcome) { outcome in
            // 表单开着时这一轮结束了：没有可改的了，收起表单让人看到结局。
            if outcome != .active { showsPlanForm = false }
        }
    }

    private var isClosed: Bool { viewModel.outcome == .closed }
    /// 过渡中（跑者刚确认，`introCall` 已清空）仍按 ③ 画：过渡只在人一直看着 ③ 时才会放。
    private var isAwaitingConfirmation: Bool {
        !isClosed && (viewModel.matchedTransition != nil || viewModel.step == .awaitingRunnerConfirmation)
    }

    /// 屏上照哪份通话数据画。跑者确认那一刻 view model 已清掉 `introCall`，前 0.3 秒照结束前那份画旧 ③。
    private var shownIntroCall: IntroCallView? {
        viewModel.introCall ?? viewModel.matchedTransition?.previousIntroCall
    }

    /// v7 ②③（#945）：与盲人端同一个外壳 —— 深色头 + 竖线（当前步「商量见面安排」）+ 底部按钮。
    /// 求助：这一态不是 `IN_PROGRESS`，`VolunteerOrderSOSMode.resolve` 恒给本地拨号。
    private var callPage: some View {
        TimelineView(.periodic(from: Date(), by: Self.clockTick)) { context in
            let incoming = viewModel.isShowingIncomingCall(now: context.date)
            BlindOrderStageScaffold(
                topBar: VolunteerOrderTopBar(
                    surface: .onDark,
                    onBack: { dismiss() },
                    menu: exitMenuItems(now: context.date),
                    counterpartSafety: safetyTarget == nil ? nil : counterpartSafety,
                    isCloudHelp: VolunteerOrderSOSMode.resolve(status: .pendingIntroCall) == .cloud,
                    onHelp: { showsLocalHelp = true },
                    messagesOrderId: route.orderId
                ),
                eyebrow: isAwaitingConfirmation ? IntroCallCopy.volunteerPlanSubmittedEyebrow : IntroCallCopy.pageTitle,
                title: title(incoming: incoming),
                headerAccessibilityLabel: headerSpoken(incoming: incoming),
                headerFocused: $headerFocused,
                headerIdentifier: .volunteerIntroCallHeader,
                place: eyebrow,
                when: nil,
                timeline: timelineInput(now: context.date),
                card: { currentCard(incoming: incoming) },
                footer: { pageFooter },
                bottom: { bottomActions }
            )
        }
        .emergencyCallOptionsDialog(isPresented: $showsLocalHelp, context: .volunteerBeforeRun, primaryContact: nil)
        .counterpartSafetyPrompts(viewModel: counterpartSafety, target: safetyTarget, blockContext: isClosed ? .standard : .introCall)
        .volunteerIntroCallExitPrompts(viewModel: viewModel, confirmsDecline: $confirmsDecline, confirmsUnreachable: $confirmsUnreachable)
        .alert(IntroCallCopy.volunteerEditPlanConfirmTitle, isPresented: $showsEditConfirm) {
            Button("取消", role: .cancel) {}
            Button(IntroCallCopy.volunteerEditPlanConfirmButton) { showsPlanForm = true }
        }
        .sheet(isPresented: $showsPlanForm) {
            planForm
        }
    }

    /// 竖线：第 1 步「已接下陪跑」，当前「商量见面安排」。
    /// ② 等来电：当前步小字是剩余时间。③ 等跑者确认（#962 第 6 项，照盲人端 ① #926）：圆点呼吸，
    /// 小字「已等 N 分钟 · 跑者确认后即完成约定」，随页面 15 秒一跳的时钟刷新；跑者确认那一刻圆点打勾。
    /// ③ 不露「下一步」：安排单五项首屏要完整可见（同盲人 v7 第 11 条 D）。
    private func timelineInput(now: Date) -> BlindOrderTimelineInput {
        var details: [BlindOrderTimelineStep: String] = [:]
        var currentDot: BlindOrderTimelineCurrentDot = .still
        var spoken: String?
        if isClosed {
            details[.arrangeMeetup] = IntroCallCopy.volunteerRoundClosedTitle
        } else if viewModel.matchedTransition != nil {
            details[.arrangeMeetup] = VolunteerIntroCallAwaitingCopy.runnerConfirmed
            currentDot = .justFound
        } else if isAwaitingConfirmation {
            let submittedAt = shownIntroCall?.plan?.submittedAt
            details[.arrangeMeetup] = VolunteerIntroCallAwaitingCopy.detail(submittedAt: submittedAt, now: now)
            currentDot = .breathing
            spoken = VolunteerIntroCallAwaitingCopy.spokenCurrentStep(submittedAt: submittedAt, now: now)
        } else if let window = IntroCallCopy.volunteerWindowPillText(
            windowEndsAt: shownIntroCall?.windowEndsAt, isAwaitingConfirmation: false, now: now
        ) {
            details[.arrangeMeetup] = window
        }
        return BlindOrderTimelineInput(
            position: .current(.arrangeMeetup),
            details: details,
            showsNextStep: !isAwaitingConfirmation,
            currentDot: currentDot,
            // 没约成不画打叉、不说「取消」：磨合里对方的表态客户端不许显示（AGENTS §5，无声拒绝是设计）。
            vocabulary: .volunteer,
            currentAccessibilityLabel: spoken
        )
    }

    /// 跑者确认那一刻的时序（#962 第 6 项，照盲人端 `playMatchFound`）：0–0.3 秒旧 ③ 圆点打勾放大回弹 →
    /// 揭开 ④（标题交叉淡入、竖线长到「等出发」）→ 1 秒定格。减弱动态效果时只做 0.25 秒淡入淡出。
    /// 震动与播报不在这里：view model 判成单时已各做一次，这里再念会把那句切断。
    /// 被取消（换了新过渡、页面关了）时 `Task.sleep` 立刻返回，整段快进到定格。
    private func playMatchedTransition() async {
        guard let id = viewModel.matchedTransition?.id else { return }
        let reduce = reduceMotion
        if !reduce {
            try? await Task.sleep(nanoseconds: Self.nanoseconds(BlindMatchFoundTiming.checkPhase))
        }
        // 只是淡入淡出（两支都是 `.transition(.opacity)`），本身就是减弱动态效果时的降级形态。
        withAnimation(.easeInOut(duration: BlindMatchFoundTiming.crossfade)) { // guard:allow motion-not-gated
            viewModel.revealMatchedTransition(id)
        }
        let rest = reduce ? BlindMatchFoundTiming.crossfade : BlindMatchFoundTiming.total - BlindMatchFoundTiming.checkPhase
        try? await Task.sleep(nanoseconds: Self.nanoseconds(rest))
        viewModel.finishMatchedTransition(id)
    }

    private static func nanoseconds(_ seconds: TimeInterval) -> UInt64 {
        UInt64(seconds * 1_000_000_000)
    }

    private func headerSpoken(incoming: Bool) -> String {
        ([eyebrow?.replacingOccurrences(of: " · ", with: "，"), title(incoming: incoming).unmaskedForSpeech] + lines(incoming: incoming).map(Optional.some))
            .compactMap { $0?.nilIfBlank }
            .joined(separator: "，")
    }

    /// 当前步那张卡：② 深色块写来电号码与「聊完记得提交」，下面是跑者需要与配速；③ 是安排单摘要。
    @ViewBuilder
    private func currentCard(incoming: Bool) -> some View {
        if isAwaitingConfirmation {
            planSummaryCard
        } else if !isClosed {
            let lines = lines(incoming: incoming)
            VStack(alignment: .leading, spacing: 12) {
                if !lines.isEmpty {
                    BlindOrderStepCard(
                        lead: incoming ? IntroCallCopy.volunteerIncomingCallPill : nil,
                        body: lines.joined(separator: "\n")
                    )
                }
                // 接单前只剩导盲犬那一行 —— 视力情况与引导方式走 `disclosesBlindRunnerNotesToVolunteer` 闸，
                // 通话发生在接单之前。恢复路径上是空数组，该组件对空数组本来就什么都不渲染。
                VolunteerRunnerNeedsBanner(needs: dispatchOrder?.escortNeeds ?? [])
                paceCard
            }
        }
    }

    @ViewBuilder
    private var pageFooter: some View {
        VStack(alignment: .leading, spacing: 12) {
            if let errorMessage = viewModel.errorMessage, !isClosed {
                Text(errorMessage)
                    .flowFont(FlowV2Fonts.callout(bold: true))
                    .foregroundColor(AppColors.destructive)
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .accessibilityLabel(errorMessage)
                    .accessibilityIdentifier("volunteerIntroCallError")
            }
            // 举报 / 不再匹配此人在顶栏「···」（负责人 2026-11-25 改 11-11 的「通话页不变」），这里只留结果一行。
            CounterpartBlockOutcome(viewModel: counterpartSafety)
        }
    }

    @ViewBuilder
    private var planForm: some View {
        if let introCall = shownIntroCall {
            VolunteerMeetupPlanFormView(
                original: introCall.originalArrangement,
                editing: introCall.meetupPlan,
                windowEndsAt: introCall.windowEndsAt?.nilIfBlank?.backendTimestamp,
                timeFlexible: introCall.timeFlexible == true,
                preferredStart: introCall.preferredStartTime?.nilIfBlank?.backendTimestamp,
                flexibleWindowText: RunPlanFormat.flexibleWindow(start: introCall.plannedStartTime, end: introCall.plannedEndTime), maxLeadDays: appState.ruleParams.maxLeadDays
            ) { request, distance in
                await viewModel.submitPlan(request, distanceFromOriginal: distance)
            }
            .environmentObject(amapGeocodingService)
        }
    }

    // MARK: 头卡

    private var runnerName: String? {
        shownIntroCall?.counterpartName?.nilIfBlank
    }

    private func title(incoming: Bool) -> String {
        if isClosed { return IntroCallCopy.volunteerRoundClosedTitle }
        // 还在拉：整屏不许空白（理由同盲人侧 `blindLoadingNotice`）。
        if shownIntroCall == nil, viewModel.errorMessage == nil { return IntroCallCopy.volunteerLoadingNotice }
        // V3 时跑者又打来（他点了「有异议，打电话沟通」）：同样换成来电那句 —— 不告诉陪跑员「跑者不同意」。
        if incoming { return IntroCallCopy.volunteerIncomingCallTitle(counterpartName: runnerName) }
        if isAwaitingConfirmation { return IntroCallCopy.volunteerAwaitingConfirmationTitle(counterpartName: runnerName) }
        return IntroCallCopy.volunteerWaitingForCallTitle(counterpartName: runnerName)
    }

    /// 🚨 掩码号只用来**认人**，这一页刻意**没有**拨号按钮：号码在这一侧是单向的，
    /// 后端恒不下发志愿者能拨通的明文号（`IntroCallView.counterpartPhoneMasked` 的注释）。
    /// 把 `138****1234` 拼进 `tel:` 会拼成一个七位的、可能真打给别人的号码。
    private func lines(incoming: Bool) -> [String] {
        if isClosed { return [IntroCallCopy.volunteerRoundClosedSubtitle] }
        let masked = shownIntroCall?.counterpartPhoneMasked?.nilIfBlank
        // V1 末尾那句「聊完记得提交」（#660 V-19）：App 不知道电话打完了没有，「合适」只能靠提交表单表达。
        if incoming, let masked { return [IntroCallCopy.volunteerIncomingCallNumberLine(masked: masked), IntroCallCopy.volunteerSubmitReminder] }
        if isAwaitingConfirmation { return [IntroCallCopy.volunteerAwaitingConfirmationSubtitle] }
        guard let masked else { return shownIntroCall == nil ? [] : [IntroCallCopy.volunteerSubmitReminder] }
        return [IntroCallCopy.volunteerIncomingNumberLine(masked: masked), IntroCallCopy.volunteerSubmitReminder]
    }

    /// 出发地与时间**优先取派单载荷，取不到回落 `IntroCallView`**（两个来源同源，契约逐字）。
    /// 距离**没有回落** —— `IntroCallView` 里没有它，而编一个比空着更糟。
    ///
    /// V3 改成安排单里的生效时间与地点（视觉稿「明天 7:30 · 朝阳公园东门」），并且**不再带距离**：
    /// 派单载荷的距离量的是原集合点，地点改了之后那个数字就不对了。
    private var eyebrow: String? {
        if isAwaitingConfirmation, let summary = planSummary {
            return IntroCallCopy.eyebrow(
                plannedStart: summary.start.map(DateFormatter.aidRunBackendLocalDateTime.string(from:)),
                address: summary.address
            )
        }
        return IntroCallCopy.eyebrow(
            plannedStart: dispatchOrder?.plannedStart?.nilIfBlank ?? shownIntroCall?.plannedStartTime,
            address: dispatchOrder?.startAddress?.nilIfBlank ?? shownIntroCall?.startAddress,
            distanceKm: dispatchOrder?.distanceKm
        )
    }

    // MARK: V3 安排摘要

    private var planSummary: VolunteerMeetupPlanSummary? {
        guard let introCall = shownIntroCall, let plan = introCall.meetupPlan else { return nil }
        return VolunteerMeetupPlanSummary.make(plan: plan, original: introCall.originalArrangement)
    }

    /// 改过的项标「已变更」（浅蓝小标签，不用删除线 —— 读屏念不出删除线）。
    /// 这一版读不懂（`hasUnreadablePlan`）时不画：读坏的时间会被当成「按原约」，摘要会说错。
    @ViewBuilder
    private var planSummaryCard: some View {
        if let summary = planSummary, !summary.rows.isEmpty {
            VolunteerV7InfoBox {
                VStack(alignment: .leading, spacing: 0) {
                    ForEach(Array(summary.rows.enumerated()), id: \.element.id) { index, row in
                        if index > 0 { FlowSeparator() }
                        VStack(alignment: .leading, spacing: 6) {
                            HStack(spacing: 8) {
                                Text(row.label)
                                    .flowFont(FlowV2Fonts.subhead())
                                    .foregroundColor(AppColors.Flow.secondaryText)
                                if row.isChanged {
                                    FlowTag(text: VolunteerMeetupPlanCopy.changedTag)
                                }
                            }
                            Text(row.value)
                                .flowFont(FlowV2Fonts.headline())
                                .foregroundColor(AppColors.Flow.primaryText)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.horizontal, 18)
                        .padding(.vertical, 14)
                        .accessibilityElement(children: .ignore)
                        .accessibilityLabel(row.accessibilityLabel)
                    }
                }
            }
            .accessibilityElement(children: .contain)
            .accessibilityIdentifier("volunteerIntroCallPlanSummary")
        }
    }

    /// 配速。只在派单载荷里有（恢复路径上没有就不画，**不摆「暂无」占位**）。
    @ViewBuilder
    private var paceCard: some View {
        if let pace = dispatchOrder?.pacePreference?.nilIfBlank {
            let text = PacePreference(rawValue: pace)?.displayName ?? pace
            VolunteerV7InfoBox {
                FlowInfoRow(label: "配速", accessibilityLabel: "配速，\(text)") {
                    Text(text)
                        .flowFont(FlowFonts.rowValue())
                        .foregroundColor(AppColors.Flow.primaryText)
                        .fixedSize(horizontal: false, vertical: true)
                        .multilineTextAlignment(.trailing)
                }
            }
            .accessibilityIdentifier("volunteerIntroCallOrderFacts")
        }
    }

    // MARK: 底栏

    /// 底部只留一枚按钮，同盲人端（负责人 2026-11-25，稿 `volunteer-intro-call-actions-20261125/`）。
    /// 「不合适」「未接到来电」在顶栏「···」：确认框照旧，「未接到来电」前几分钟灰着并写明何时可用（#660 V-9）。
    @ViewBuilder
    private var bottomActions: some View {
        VStack(spacing: FlowMetrics.actionButtonSpacing) {
            if isClosed {
                // V4′：留在这一页，等陪跑员自己点（v6 停 3 秒自动关页，会截断那句播报）。
                BlindOrderStageButton(title: IntroCallCopy.volunteerBackHomeButtonTitle, style: .solid) { dismiss() }
                    .accessibilityIdentifier("volunteerOrderFlowPrimaryButton")
            } else if isAwaitingConfirmation {
                // V3：此刻没有该他做的主动作 —— 不放实心主按钮。
                awaitingConfirmationButtons
            } else {
                BlindOrderStageButton(
                    title: IntroCallCopy.volunteerFillPlanButtonTitle,
                    style: .solid,
                    isEnabled: !viewModel.isSubmitting && shownIntroCall != nil,
                    accessibilityHint: IntroCallCopy.volunteerFillPlanAccessibilityHint
                ) {
                    showsPlanForm = true
                }
                .accessibilityIdentifier("volunteerOrderFlowPrimaryButton")
            }
        }
        .padding(.bottom, 4)
    }

    /// V3：只有「修改见面安排」（先提示需跑者重新确认）；「不合适」在「···」。
    private var awaitingConfirmationButtons: some View {
        BlindOrderStageButton(
            title: IntroCallCopy.volunteerEditPlanButtonTitle,
            style: .outline,
            isEnabled: !viewModel.isSubmitting,
            accessibilityHint: IntroCallCopy.volunteerEditPlanConfirmTitle
        ) {
            showsEditConfirm = true
        }
        .accessibilityIdentifier("volunteerIntroCallEditPlanButton")
    }
}

// 放在扩展里：结构体本体已超 SwiftLint type_body_length，棘轮只许它变短。
extension VolunteerIntroCallView {
    fileprivate var safetyTarget: CounterpartSafetyTarget? {
        CounterpartSafetyGate.target(userId: viewModel.counterpartUserId, orderId: route.orderId)
    }

    /// 「···」里这次沟通的两项（`VolunteerIntroCallMenu`）。② 两项都有；③ 只有「不合适」；本轮结束后都没有。
    fileprivate func exitMenuItems(now: Date) -> [VolunteerOrderMenuItem] {
        guard !isClosed, viewModel.matchedTransition == nil else { return [] }
        let firstSeen = isAwaitingConfirmation ? nil : VolunteerIntroCallUnreachableGate.noteSeen(
            .init(orderId: route.orderId, windowEndsAt: viewModel.introCall?.windowEndsAt)
        )
        return VolunteerIntroCallMenu.items(
            offersDecline: true,
            unreachableFirstSeen: firstSeen,
            now: now,
            isSubmitting: viewModel.isSubmitting,
            decline: { confirmsDecline = true },
            unreachable: { confirmsUnreachable = true }
        )
    }
}

/// v7 抽屉里的信息块：浅灰圆角底（同盲人 v7 ③ 安排单），取代 v2 的白卡（白卡压在白底抽屉上只剩一圈阴影）。
struct VolunteerV7InfoBox<Content: View>: View {
    @ViewBuilder let content: () -> Content

    var body: some View {
        content().modifier(VolunteerV7InfoBoxBackground())
    }
}

/// 信息块的底。`VolunteerV7InfoBox` 与订单页信息块共用这一份。
struct VolunteerV7InfoBoxBackground: ViewModifier {
    func body(content: Content) -> some View {
        content.background(RoundedRectangle(cornerRadius: 16, style: .continuous).fill(AppColors.Flow.surfaceSubtle))
    }
}
