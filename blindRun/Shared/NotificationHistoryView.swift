import SwiftUI

/// 消息历史页，两端共用（#1025）。数据源 `GET /api/notifications/history`，正文直接显示后端渲染好的 `body`。
///
/// 两种用法：
/// - 「我的」页 push 进来：`orderId == nil`，全部消息；
/// - 订单页「···」里的「这一单的消息」：`NotificationHistorySheet` 包一层，`orderId` 过滤。
///   订单页 v7 自己画顶栏、藏了系统导航栏，push 过去没有返回键，所以走 sheet。
///
/// 🔴 读屏：一行一个焦点，先念正文、再念时间，高优先级的末尾加「重要消息」（`rowAccessibilityLabel`）。
/// 翻页不做滚动到底自动加载，用一个 64pt 的按钮：读屏用户能听到它、能决定要不要再读更早的。
struct NotificationHistoryView: View {
    @EnvironmentObject private var appState: AppState
    @EnvironmentObject private var speechService: SpeechService
    @StateObject private var viewModel: NotificationHistoryViewModel
    /// 非 nil = 在 sheet 里，导航栏右上角给一个「完成」。
    private let onClose: (() -> Void)?

    init(orderId: Int64? = nil, onClose: (() -> Void)? = nil) {
        _viewModel = StateObject(wrappedValue: NotificationHistoryViewModel(orderId: orderId))
        self.onClose = onClose
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 12) {
                content
            }
            .padding(.horizontal, 16)
            .padding(.top, 8)
            .padding(.bottom, 32)
            .frame(maxWidth: .infinity, alignment: .leading)
            .readableContentColumn()
        }
        .background(AppColors.Flow.page)
        .navigationTitle(viewModel.isForOrder ? NotificationHistoryCopy.orderTitle : NotificationHistoryCopy.title)
        .navigationBarTitleDisplayMode(onClose == nil ? .large : .inline)
        .toolbar(.hidden, for: .tabBar) // 二级页藏标签栏（记忆 tab-bar-clips-the-last-line-of-secondary-pages）
        .toolbar {
            if let onClose {
                ToolbarItem(placement: .confirmationAction) {
                    Button(NotificationHistoryCopy.close, action: onClose)
                        .accessibilityIdentifier("notificationHistoryCloseButton")
                }
            }
        }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("notificationHistoryView")
        .task { await viewModel.load(service: appState.notificationHistory) }
        .refreshable { await viewModel.load(service: appState.notificationHistory) }
        // 空列表要念出来：它是一行普通文字，读屏焦点停在导航栏标题上，不会自己去读它。
        .onChange(of: isEmptyListing) { isEmpty in
            if isEmpty { speechService.speak(NotificationHistoryCopy.emptyText(forOrder: viewModel.isForOrder)) }
        }
    }

    private var isEmptyListing: Bool {
        if case .loaded(let listing) = viewModel.phase { return listing.items.isEmpty }
        return false
    }

    // MARK: 内容

    /// 失败走 `RemoteContent`：会念出来，不只是一行红字（#864）。
    private var content: some View {
        RemoteContent(
            viewModel.phase,
            loadingLabel: NotificationHistoryCopy.loading,
            failureIdentifier: "notificationHistoryRetry",
            retryTitle: NotificationHistoryCopy.retry,
            retry: { Task { await viewModel.retry(service: appState.notificationHistory) } }
        ) { listing in
            if listing.items.isEmpty {
                Text(NotificationHistoryCopy.emptyText(forOrder: viewModel.isForOrder))
                    .font(AppFonts.body())
                    .foregroundColor(AppColors.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
                    .accessibilityIdentifier("notificationHistoryEmpty")
            } else {
                ForEach(listing.items) { row($0) }
                footer(listing)
            }
        }
    }

    private func row(_ item: NotificationHistoryItem) -> some View {
        let time = NotificationHistoryTime.display(sentAt: item.sentAt)
        return VStack(alignment: .leading, spacing: 8) {
            if time != nil || item.isHighPriority {
                AdaptiveHStack(spacing: 8) {
                    if item.isHighPriority { highPriorityTag }
                    if let time {
                        Text(time)
                            .font(.subheadline)
                            .foregroundColor(AppColors.textSecondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    Spacer(minLength: 0)
                }
            }
            Text(item.body)
                .font(AppFonts.body())
                .foregroundColor(AppColors.textPrimary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(GroupedCardMetrics.rowHorizontalPadding)
        .background(AppColors.Flow.surface)
        .clipShape(RoundedRectangle(cornerRadius: GroupedCardMetrics.cardRadius, style: .continuous))
        // 一行一个焦点，念法固定：正文 → 时间 → 重要。
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(NotificationHistoryCopy.rowAccessibilityLabel(item))
        .accessibilityIdentifier("notificationHistoryRow")
    }

    /// 带底色的文字标记，颜色不是唯一区分。字用主文字色（同 `MySupportTicketsView.statusTag` 的对比度考虑）。
    private var highPriorityTag: some View {
        Text(NotificationHistoryCopy.highPriorityTag)
            .font(.footnote.weight(.semibold))
            .foregroundColor(AppColors.textPrimary)
            .padding(.horizontal, 8)
            .padding(.vertical, 3)
            .background(
                RoundedRectangle(cornerRadius: 6, style: .continuous)
                    .fill(AppColors.destructive.opacity(0.16))
            )
            .fixedSize(horizontal: false, vertical: true)
    }

    // MARK: 列表尾

    @ViewBuilder
    private func footer(_ listing: NotificationHistoryViewModel.Listing) -> some View {
        if listing.nextPage == nil {
            Text(NotificationHistoryCopy.endText(forOrder: viewModel.isForOrder))
                .font(.subheadline)
                .foregroundColor(AppColors.textSecondary)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: .infinity, alignment: .leading)
                .accessibilityIdentifier("notificationHistoryEnd")
        } else if listing.moreState == .loading {
            HStack(spacing: 8) {
                ProgressView()
                Text(NotificationHistoryCopy.loadingMore)
                    .font(AppFonts.body())
                    .foregroundColor(AppColors.textSecondary)
            }
            .frame(maxWidth: .infinity, minHeight: AppTouchTarget.blindPrimary, alignment: .leading)
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(NotificationHistoryCopy.loadingMore)
        } else {
            VStack(alignment: .leading, spacing: 4) {
                if listing.moreState == .failed {
                    Text(NotificationHistoryCopy.loadMoreFailed)
                        .font(AppFonts.body())
                        .foregroundColor(AppColors.textPrimary)
                        .fixedSize(horizontal: false, vertical: true)
                        .announcesFailure(NotificationHistoryCopy.loadMoreFailed, using: speechService, attempt: loadMoreAttempt)
                }
                Button(listing.moreState == .failed ? NotificationHistoryCopy.retry : NotificationHistoryCopy.loadMore) {
                    loadMoreAttempt += 1
                    Task {
                        if let added = await viewModel.loadMore(service: appState.notificationHistory) {
                            speechService.speak(NotificationHistoryCopy.loadedMore(added))
                        }
                    }
                }
                .buttonStyle(TextButtonStyle())
                .accessibilityIdentifier("notificationHistoryLoadMore")
            }
        }
    }

    /// 翻页失败后用户点了几次重试。同一句失败文案再次失败时靠它再念一遍（同 `RemoteContent.attempt`）。
    @State private var loadMoreAttempt = 0
}

/// 订单页「这一单的消息」：sheet 里套一层导航栈，右上角「完成」关掉。
struct NotificationHistorySheet: View {
    let orderId: Int64
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            NotificationHistoryView(orderId: orderId, onClose: { dismiss() })
        }
    }
}

/// 「我的」页列表里的「消息」一行，两端共用。放在列表第一行：读屏从标签栏进「我的」，划过头像和方块后就是它。
struct NotificationHistoryEntryRow: View {
    var body: some View {
        NavigationLink {
            NotificationHistoryView()
        } label: {
            SettingsRowLabel(title: NotificationHistoryCopy.title)
        }
        .buttonStyle(.plain)
        .accessibilityLabel(NotificationHistoryCopy.title)
        .accessibilityHint(NotificationHistoryCopy.settingsHint)
        .accessibilityIdentifier("notificationHistorySettingsEntry")
    }
}
