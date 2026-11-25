import Foundation
@testable import blindRun

/// `NotificationHistoryServing` 的测试替身。规矩同 `FakeIncentiveService`：不含任何业务判定，
/// 只记一笔调用、按顺序吐构造时塞进来的罐装结果；罐装的用完了就抛 `NotStubbed`，忘了打桩当场红。
final class FakeNotificationHistoryService: NotificationHistoryServing, @unchecked Sendable {
    struct NotStubbed: Error {}

    struct Call: Equatable {
        let orderId: Int64?
        let page: Int
        let size: Int
    }

    private let lock = NSLock()
    private var queue: [Result<NotificationHistoryPage, Error>]
    private var _calls: [Call] = []
    /// 设了就在返回前先等它（演「请求在飞的时候用户又刷新了一次」）。
    var gate: (@Sendable () async -> Void)?

    init(_ results: [Result<NotificationHistoryPage, Error>] = []) {
        queue = results
    }

    var calls: [Call] { lock.withLock { _calls } }

    func history(orderId: Int64?, page: Int, size: Int) async throws -> NotificationHistoryPage {
        let next: Result<NotificationHistoryPage, Error> = lock.withLock {
            _calls.append(Call(orderId: orderId, page: page, size: size))
            return queue.isEmpty ? .failure(NotStubbed()) : queue.removeFirst()
        }
        if let gate { await gate() }
        return try next.get()
    }
}
