//
//  APIError+ServerUnavailable.swift
//  blindRun
//
//  宕机、网关报错、连不上服务器时单独说清（#659，审计 F-7）。写法照 `APIError+SecureConnection.swift`。
//

import CoreTelephony
import Foundation

extension APIError {
    /// 手机这边确实没有网络。**只有这一种**才叫用户去检查网络。
    static let offlineMessage = "网络连接失败，请检查网络设置。"

    /// 服务器连不上，或网关回 5xx。不叫用户检查网络：盲人用户无从判断问题在哪一边，
    /// 说「检查网络」会让他去反复开关飞行模式。最后一句留给紧急情况，因为此刻 App 帮不上忙。
    /// 不写「不是你的手机」这类撇清的话（#954）。
    static let serverUnavailableMessage = "服务暂时出了问题，请稍后再试。紧急情况请拨打120。"

    /// 请求超时或连接中途断开。**两边都可能**：弱网（地下通道）和服务器卡住表现一样，
    /// 所以不只叫用户检查网络，也不猜原因（#954）。
    static let ambiguousConnectionMessage = "暂时连不上服务器，请稍后再试。紧急情况请拨打120。"

    enum NetworkFailureKind: Equatable {
        case secureConnection
        case offline
        case serverUnreachable
        case ambiguous
    }

    /// 按 `URLError` 分类。不认识的错误（含非 `NSURLErrorDomain`）退回 `.offline`，与改动前的文案一致。
    static func networkFailureKind(_ error: Error) -> NetworkFailureKind {
        if isSecureConnectionFailure(error) { return .secureConnection }
        let nsError = error as NSError
        guard nsError.domain == NSURLErrorDomain else { return .offline }
        let code = URLError.Code(rawValue: nsError.code)
        if serverUnreachableCodes.contains(code) { return .serverUnreachable }
        if ambiguousCodes.contains(code) { return .ambiguous }
        return .offline
    }

    static func networkFailureMessage(
        _ error: Error,
        permission: CTCellularDataRestrictedState = NetworkPermission.currentState
    ) -> String {
        let kind = networkFailureKind(error)
        if NetworkPermission.isAwaitingPermission(state: permission, failure: kind) {
            return NetworkPermission.message // 联网授权还没给（#1008）
        }
        switch kind {
        case .secureConnection: return secureConnectionMessage
        case .offline: return offlineMessage
        case .serverUnreachable: return serverUnavailableMessage
        case .ambiguous: return ambiguousConnectionMessage
        }
    }

    /// 嵌进「求助未发出：<原因>。请重试，或直接拨打110。」这类整句里的原因短语。
    /// 整句自带下一步，`localizedMessage` 里的「请稍后再试」「拨打120」会和它打架 ——
    /// 求助场景尤其不能叫人「稍后」。断网与证书错误仍用原文，与改动前一致。
    var reasonClause: String {
        switch self {
        case .networkError(let underlying):
            switch Self.networkFailureKind(underlying) {
            case .secureConnection, .offline: return localizedMessage
            case .serverUnreachable: return Self.serverUnavailableReason
            case .ambiguous: return "暂时连不上服务器"
            }
        case .unknown(let statusCode) where Self.isServerSideStatus(statusCode):
            return Self.serverUnavailableReason
        default:
            return localizedMessage
        }
    }

    private static let serverUnavailableReason = "服务暂时出了问题"

    /// 网关和服务器报的 5xx。没有后端错误体时才会走到 `.unknown`（有错误体的走 `.serverError`）。
    /// 网关 502 / 503 / 504 就是这样到的，原来念「未知错误 (502)」—— 状态码对用户没有用。
    static func isServerSideStatus(_ statusCode: Int) -> Bool {
        (500...599).contains(statusCode)
    }

    /// 手机有网，但找不到或连不上服务器。`cannotFindHost` / `dnsLookupFailed` 放在这里：
    /// 手机真没网时系统先报 `notConnectedToInternet`，走不到域名解析这一步。
    private static let serverUnreachableCodes: Set<URLError.Code> = [
        .cannotConnectToHost, .cannotFindHost, .dnsLookupFailed, .badServerResponse
    ]

    private static let ambiguousCodes: Set<URLError.Code> = [
        .timedOut, .networkConnectionLost
    ]
}

/// 断网类失败先自己重试几次，都不成功才报错（2026-11-26 负责人定）。
///
/// 起因：陪跑员点「陪跑员认证」时手机断网约一分钟，App 一次没重试就整页换成「暂时无法恢复账号资料」。
/// 只重试能在原地好起来的失败：断网、连不上服务器、超时、连接中途断开（`.networkError`）。
/// - 证书错误重试也不会好，不重试。
/// - 服务端回了答复（401、4xx、5xx、解码失败）交给调用方原来的分支，不重试。
/// - 取消立刻抛出：根路由换页时会取消旧的加载，不能还在后台等。
///
/// 用在冷启动校验会话（`restoreSession`）和根路由加载资料（`ContentRootRouter.hydrate`，
/// 含陪跑员注册状态：它的 `try?` 降级判定可能把已完成注册的人送回认证页，所以断网时也先重试）。
enum TransientNetworkRetry {
    /// 第 1 次失败后等 1 秒、第 2 次失败后等 2 秒，一共试 3 次。
    /// 单次请求超时是 15 秒（`URLSessionAPIClient`），全超时最坏约 48 秒，期间页面显示「正在恢复账号资料」。
    static let defaultDelaysNanoseconds: [UInt64] = [1_000_000_000, 2_000_000_000]

    /// 实际用的间隔。只有单测改它（改成 0，不真等），改完要在 `tearDown` 还原。
    static var delaysNanoseconds = defaultDelaysNanoseconds

    static func run<T>(
        delaysNanoseconds: [UInt64] = delaysNanoseconds,
        _ operation: () async throws -> T
    ) async throws -> T {
        var remainingDelays = delaysNanoseconds[...]
        while true {
            do {
                return try await operation()
            } catch {
                guard isTransient(error), !Task.isCancelled, let delay = remainingDelays.popFirst() else { throw error }
                try await Task.sleep(nanoseconds: delay)
            }
        }
    }

    static func isTransient(_ error: Error) -> Bool {
        guard case .networkError(let underlying)? = error as? APIError else { return false }
        if (underlying as? URLError)?.code == .cancelled { return false }
        return APIError.networkFailureKind(underlying) != .secureConnection
    }
}
