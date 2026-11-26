import XCTest
@testable import blindRun

/// 启动恢复失败页的「重试恢复」（#573），和恢复前的断网自动重试（2026-11-26）。
///
/// #573 修之前按钮只调 `synchronize`：会话校验失败（断网）时它按现有状态重选页面、不发请求，
/// 网络恢复后点了也原样不动。下面用 `/api/auth/me` 的调用次数区分各种实现。
///
/// 2026-11-26 起断网类失败先自己试 `attempts` 次才落到失败页（`TransientNetworkRetry`）：
/// 陪跑员点「陪跑员认证」时手机断网约一分钟，App 一次没重试就整页报错。
@MainActor
final class RecoveryRetryTests: XCTestCase {

    /// 一共试几次 = 1 + 间隔个数。
    private static let attempts = TransientNetworkRetry.defaultDelaysNanoseconds.count + 1

    override func setUp() {
        super.setUp()
        // 不真等 1 秒、2 秒；次数照旧。
        TransientNetworkRetry.delaysNanoseconds = TransientNetworkRetry.defaultDelaysNanoseconds.map { _ in 0 }
    }

    override func tearDown() {
        TransientNetworkRetry.delaysNanoseconds = TransientNetworkRetry.defaultDelaysNanoseconds
        super.tearDown()
    }

    // MARK: - 自动重试

    /// 断两次、第三次通。旧实现第一次失败就停在失败页（meCalls == 1）。
    func testBriefOutageIsRetriedAutomaticallyBeforeShowingTheFailurePage() async {
        let (appState, client, persistence) = Self.makeStoredSession(failingMeCalls: Self.attempts - 1)
        defer { persistence.reset() }

        await appState.restoreSession()

        XCTAssertEqual(client.meCalls, Self.attempts)
        XCTAssertEqual(appState.sessionRestorationState, .authenticated)
    }

    /// 一直断：恰好试 `attempts` 次就停，落到失败页让人点「重试恢复」。
    /// 次数写死成等式：多试一次（无限重试）或少试一次都会让这条失败。
    func testPersistentOutageGivesUpAfterTheConfiguredAttempts() async {
        let (appState, client, persistence) = Self.makeStoredSession(failingMeCalls: 100)
        defer { persistence.reset() }

        await appState.restoreSession()

        XCTAssertEqual(client.meCalls, Self.attempts)
        guard case .validationFailed = appState.sessionRestorationState else {
            return XCTFail("应落到校验失败，实际 \(appState.sessionRestorationState)")
        }
    }

    /// 401 是服务端的明确答复，重试不会变：只请求一次，直接按「登录状态已失效」收尾。
    func testUnauthorizedIsNotRetried() async {
        let (appState, client, persistence) = Self.makeStoredSession(failingMeCalls: 100, failure: .unauthorized)
        defer { persistence.reset() }

        await appState.restoreSession()

        XCTAssertEqual(client.meCalls, 1)
        XCTAssertEqual(appState.sessionRestorationState, .unauthenticated)
    }

    /// 哪些失败算「断网类」。证书错误重试也不会好；取消是根路由换页，要立刻停。
    func testOnlyNetworkFailuresThatCanRecoverAreRetried() {
        XCTAssertTrue(TransientNetworkRetry.isTransient(APIError.networkError(URLError(.notConnectedToInternet))))
        XCTAssertTrue(TransientNetworkRetry.isTransient(APIError.networkError(URLError(.timedOut))))
        XCTAssertTrue(TransientNetworkRetry.isTransient(APIError.networkError(URLError(.networkConnectionLost))))
        XCTAssertTrue(TransientNetworkRetry.isTransient(APIError.networkError(URLError(.cannotConnectToHost))))

        XCTAssertFalse(TransientNetworkRetry.isTransient(APIError.networkError(URLError(.serverCertificateUntrusted))))
        XCTAssertFalse(TransientNetworkRetry.isTransient(APIError.networkError(URLError(.cancelled))))
        XCTAssertFalse(TransientNetworkRetry.isTransient(APIError.unauthorized))
        XCTAssertFalse(TransientNetworkRetry.isTransient(APIError.unknown(statusCode: 503)))
        XCTAssertFalse(TransientNetworkRetry.isTransient(CancellationError()))
    }

    // MARK: - 「重试恢复」按钮（#573）

    func testRetryAfterSessionValidationFailureValidatesAgainAndSucceeds() async {
        let (appState, client, persistence) = Self.makeStoredSession(failingMeCalls: Self.attempts)
        defer { persistence.reset() }
        let router = ContentRootRouter()
        await appState.restoreSession()
        router.synchronize(with: appState)
        guard case .recoveryFailed = router.route else { return XCTFail("前提：先落到恢复失败页，实际 \(router.route)") }

        await router.retryRecovery(with: appState)

        XCTAssertEqual(client.meCalls, Self.attempts + 1, "重试要重新校验会话")
        XCTAssertEqual(appState.sessionRestorationState, .authenticated)
        XCTAssertEqual(router.failedRecoveryRetries, 0, "成功了不该触发失败重念")
    }

    /// 又失败时：仍在恢复失败页，且重试次数加一 —— 失败页靠它把原因再念一遍，不能静默。
    func testRetryThatFailsAgainStaysOnTheFailurePageAndBumpsTheAnnouncement() async {
        let (appState, client, persistence) = Self.makeStoredSession(failingMeCalls: Self.attempts * 2)
        defer { persistence.reset() }
        let router = ContentRootRouter()
        await appState.restoreSession()

        await router.retryRecovery(with: appState)
        router.synchronize(with: appState)

        XCTAssertEqual(client.meCalls, Self.attempts * 2)
        guard case .validationFailed = appState.sessionRestorationState else {
            return XCTFail("应仍是校验失败，实际 \(appState.sessionRestorationState)")
        }
        guard case .recoveryFailed = router.route else { return XCTFail("应仍在恢复失败页，实际 \(router.route)") }
        XCTAssertEqual(router.failedRecoveryRetries, 1)
    }

    // MARK: - 回到前台

    /// 停在恢复失败页时回到前台：自己重新校验会话，网好了就进去，不用人点。
    func testForegroundRetriesWhenStuckOnTheFailurePage() async {
        let (appState, client, persistence) = Self.makeStoredSession(failingMeCalls: Self.attempts)
        defer { persistence.reset() }
        let router = ContentRootRouter()
        await appState.restoreSession()
        router.synchronize(with: appState)
        guard case .recoveryFailed = router.route else { return XCTFail("前提：先落到恢复失败页，实际 \(router.route)") }

        await router.retryRecoveryIfFailed(with: appState)

        XCTAssertEqual(client.meCalls, Self.attempts + 1)
        XCTAssertEqual(appState.sessionRestorationState, .authenticated)
    }

    /// 不在失败页时回到前台：不发请求。否则每次切回 App 都会重校验一遍会话。
    func testForegroundDoesNothingWhenNotOnTheFailurePage() async {
        let (appState, client, persistence) = Self.makeStoredSession(failingMeCalls: 0)
        defer { persistence.reset() }
        // 不调 `synchronize`：它会在后台拉资料，本客户端让资料加载失败，路由可能自己跳到失败页。
        // 路由停在初始的 `.restoringAccount`，正好是「不在失败页」。
        let router = ContentRootRouter()
        await appState.restoreSession()
        let callsAfterLaunch = client.meCalls

        await router.retryRecoveryIfFailed(with: appState)

        XCTAssertEqual(client.meCalls, callsAfterLaunch)
    }

    // MARK: - 场景

    private static func makeStoredSession(
        failingMeCalls: Int,
        failure: APIError = .networkError(URLError(.notConnectedToInternet))
    ) -> (AppState, FlakyMeAPIClient, UserDefaultsAppStatePersistence) {
        let persistence = AppStatePersistenceFactory.makeIsolatedTest()
        persistence.set("stored-token", forKey: AppConstants.UserDefaultsKeys.accessToken)
        persistence.set(Int64(77), forKey: AppConstants.UserDefaultsKeys.userId)
        persistence.set(UserRole.blind.rawValue, forKey: AppConstants.UserDefaultsKeys.activeRole)
        let client = FlakyMeAPIClient(failingMeCalls: failingMeCalls, failure: failure)
        return (AppState(apiClient: client, persistence: persistence), client, persistence)
    }

    /// `/api/auth/me` 前 N 次抛 `failure`、之后成功；其余端点一律失败（会话恢复成功后的副作用请求不影响断言）。
    final class FlakyMeAPIClient: APIClientProtocol, @unchecked Sendable {
        private let failingMeCalls: Int
        private let failure: APIError
        private(set) var meCalls = 0

        init(failingMeCalls: Int, failure: APIError) {
            self.failingMeCalls = failingMeCalls
            self.failure = failure
        }

        func request<T: Decodable>(
            method: HTTPMethod,
            path: String,
            query: [String: String]?,
            body: (any Encodable & Sendable)?,
            requiresAuth: Bool
        ) async throws -> T {
            guard method == .get, path == "/api/auth/me" else { throw APIError.invalidURL }
            meCalls += 1
            if meCalls <= failingMeCalls { throw failure }
            guard let response = CurrentUserResponse(userId: 77, phone: nil, role: "BLIND") as? T else {
                throw APIError.invalidURL
            }
            return response
        }

        func upload<T: Decodable>(
            path: String,
            query: [String: String]?,
            fields: [String: String]?,
            files: [MultipartFile],
            requiresAuth: Bool
        ) async throws -> T {
            throw APIError.invalidURL
        }
    }
}
