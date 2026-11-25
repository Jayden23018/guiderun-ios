import Combine
import Foundation

/// 消息历史页的状态。**只用 async/await**，不持有 `AnyCancellable`。
///
/// 三条规矩，都是因为这一页的读者多半看不见屏幕：
/// 1. 读取失败**不等于**没有消息：首页失败是 `.failed`，不落成空列表（否则失败会被说成「没有收到消息」）。
/// 2. 下拉刷新失败时保留已经显示的列表：用户正在读的那几条不该因为一次刷新失败消失。
/// 3. 「到底了」只在后端说没有下一页时才成立；翻页失败停在「重试」，不当作到底。
@MainActor
final class NotificationHistoryViewModel: ObservableObject {
    struct Listing: Equatable {
        var items: [NotificationHistoryItem]
        /// 下一页的页号；nil = 到底了。
        var nextPage: Int?
        var moreState: MoreState
    }

    enum MoreState: Equatable {
        case idle
        case loading
        case failed
    }

    /// 后端上限 50；20 是一屏半的量，读屏用户不用一次划过太长的列表。
    static let pageSize = 20

    @Published private(set) var phase: AsyncLoadState<Listing> = .idle

    /// nil = 全部消息；非 nil = 订单页「这一单的消息」。
    let orderId: Int64?

    /// 每次**从头加载成功**加一。翻页请求回来时拿它对账：期间列表被刷新换过，就丢掉这批旧页，
    /// 否则旧列表的第 2 页会接在新列表的第 1 页后面。
    /// 只在成功时加：刷新失败时列表没换，在飞的翻页结果仍然有效；若失败也加，那次翻页的结果被丢掉，
    /// 「更多」会永远停在「正在读取」。
    private var generation = 0
    /// 每次发起从头加载加一，只用来丢掉先发后到的那次从头加载。
    private var loadSeq = 0

    init(orderId: Int64? = nil) {
        self.orderId = orderId
    }

    var isForOrder: Bool { orderId != nil }

    /// 首页。首次进入与下拉刷新都走这里。
    func load(service: any NotificationHistoryServing) async {
        loadSeq += 1
        let mine = loadSeq
        do {
            let page = try await service.history(orderId: orderId, page: 0, size: Self.pageSize)
            guard mine == loadSeq else { return }
            generation += 1
            phase = .loaded(Listing(
                items: Self.dedup(page.content),
                nextPage: page.hasMore(requestedSize: Self.pageSize) ? 1 : nil,
                moreState: .idle
            ))
        } catch let error as APIError {
            if !error.endsSession, mine == loadSeq { markFailedUnlessAlreadyShowing() }
        } catch is CancellationError {
            return
        } catch {
            if mine == loadSeq { markFailedUnlessAlreadyShowing() }
        }
    }

    func retry(service: any NotificationHistoryServing) async {
        phase = .loading(requestID: UUID())
        await load(service: service)
    }

    /// 下一页。返回这次新增了几条（给页面朗读用）；没有发起请求或失败返回 nil。
    @discardableResult
    func loadMore(service: any NotificationHistoryServing) async -> Int? {
        guard case .loaded(var listing) = phase,
              let page = listing.nextPage,
              listing.moreState != .loading else { return nil }
        let mine = generation
        listing.moreState = .loading
        phase = .loaded(listing)
        do {
            let response = try await service.history(orderId: orderId, page: page, size: Self.pageSize)
            guard mine == generation, case .loaded(var current) = phase else { return nil }
            let known = Set(current.items.map(\.id))
            // 翻页期间有新通知进来会把后面的行整体挤一格，同一条可能在两页都出现：按 id 去重。
            let fresh = Self.dedup(response.content).filter { !known.contains($0.id) }
            current.items += fresh
            current.nextPage = response.hasMore(requestedSize: Self.pageSize) ? page + 1 : nil
            current.moreState = .idle
            phase = .loaded(current)
            return fresh.count
        } catch {
            guard mine == generation, case .loaded(var current) = phase else { return nil }
            // 会话失效由网络层统一处理；这里只把「更多」退回可重试，不改已经显示的列表。
            let isQuiet = (error as? APIError)?.endsSession == true || error is CancellationError
            current.moreState = isQuiet ? .idle : .failed
            phase = .loaded(current)
            return nil
        }
    }

    private func markFailedUnlessAlreadyShowing() {
        if case .loaded = phase { return }
        phase = .failed(message: NotificationHistoryCopy.failed)
    }

    private static func dedup(_ items: [NotificationHistoryItem]) -> [NotificationHistoryItem] {
        var seen = Set<Int64>()
        return items.filter { seen.insert($0.id).inserted }
    }
}
