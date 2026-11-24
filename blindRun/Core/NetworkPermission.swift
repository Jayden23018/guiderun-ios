//
//  NetworkPermission.swift
//  blindRun
//
//  国行 iPhone 新装 App 第一次联网前，系统弹「允许使用无线数据」。点允许之前请求直接失败，
//  表现和断网一样（#1008）。这里判断「是不是联网授权还没给」，并在授权后通知 App 重试。
//

import CoreTelephony
import Foundation

enum NetworkPermission {
    /// 授权没给，并且这次失败看起来像断网：才说「请允许联网」。
    /// 只看 `.offline`：服务器连不上、超时说明请求已经发出去了，授权不是原因。
    /// ponytail: `.restricted` 也含用户在设置里关掉无线数据；此时 Wi-Fi 下请求不会失败，走不到这里。
    static func isAwaitingPermission(
        state: CTCellularDataRestrictedState,
        failure: APIError.NetworkFailureKind
    ) -> Bool {
        state == .restricted && failure == .offline
    }

    /// 从「受限」变成「不受限」= 用户刚点了允许。启动时第一次回调（`previous == nil`）不算。
    static func shouldRetry(
        previous: CTCellularDataRestrictedState?,
        current: CTCellularDataRestrictedState
    ) -> Bool {
        previous == .restricted && current == .notRestricted
    }

    static let message = "还没有联网权限。请在弹窗里选择允许助盲跑使用网络，允许后会自动重试。"

    /// 当前授权状态，供 `APIError` 取文案用。回调在任意队列，所以加锁。
    static var currentState: CTCellularDataRestrictedState { monitor.state }

    /// 开始监听。授权变成允许时调 `onGranted`（主线程）。只需调一次。
    static func startMonitoring(onGranted: @escaping @MainActor () -> Void) {
        monitor.start(onGranted: onGranted)
    }

    private static let monitor = Monitor()

    private final class Monitor {
        private let cellularData = CTCellularData()
        private let lock = NSLock()
        private var latest: CTCellularDataRestrictedState = .restrictedStateUnknown
        private var previous: CTCellularDataRestrictedState?
        private var started = false

        var state: CTCellularDataRestrictedState {
            lock.lock(); defer { lock.unlock() }
            return latest
        }

        func start(onGranted: @escaping @MainActor () -> Void) {
            lock.lock()
            guard !started else { lock.unlock(); return }
            started = true
            lock.unlock()
            cellularData.cellularDataRestrictionDidUpdateNotifier = { [weak self] current in
                guard let self else { return }
                self.lock.lock()
                let before = self.previous
                self.previous = current
                self.latest = current
                self.lock.unlock()
                if NetworkPermission.shouldRetry(previous: before, current: current) {
                    Task { @MainActor in onGranted() }
                }
            }
        }
    }
}
