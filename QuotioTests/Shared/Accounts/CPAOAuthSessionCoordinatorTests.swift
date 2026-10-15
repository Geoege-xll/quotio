import Foundation
import XCTest
@testable import QuotioPlus

/// 可控响应故意忽略 Task 取消，模拟网络回调迟到；验证旧登录绝不会覆盖新会话或触发账号刷新。
final class CPAOAuthSessionCoordinatorTests: XCTestCase {
    private actor Client: CPAOAuthSessionClient {
        let name: String
        let startReached: XCTestExpectation?
        let pollReached: XCTestExpectation?
        let cancelReached: XCTestExpectation?
        let holdsStart: Bool
        let holdsPoll: Bool
        let invalidURL: Bool
        let pollFails: Bool
        let userCode: String?
        let flow: String?
        let expiresIn: Double?
        let waitsBeforeSuccess: Int
        let callbackReached: XCTestExpectation?
        let callbackFails: Bool
        private var callbackWaiter: CheckedContinuation<Void, Never>?
        private var startWaiter: CheckedContinuation<OAuthURLResponse, Never>?
        private var pollWaiter: CheckedContinuation<OAuthStatusResponse, Never>?
        var cancelled: [String] = []
        var callbacks: [(provider: AIProvider, redirectURL: String)] = []
        var pollCount = 0
        init(_ name: String, start: XCTestExpectation? = nil, poll: XCTestExpectation? = nil,
             cancel: XCTestExpectation? = nil, holdsStart: Bool = false, holdsPoll: Bool = false,
             invalidURL: Bool = false, pollFails: Bool = false, userCode: String? = nil,
             flow: String? = nil, expiresIn: Double? = nil, waitsBeforeSuccess: Int = 0,
             callback: XCTestExpectation? = nil, callbackFails: Bool = false) {
            self.name = name; self.startReached = start; self.pollReached = poll; self.cancelReached = cancel
            self.holdsStart = holdsStart; self.holdsPoll = holdsPoll; self.invalidURL = invalidURL; self.pollFails = pollFails
            self.userCode = userCode
            self.flow = flow; self.expiresIn = expiresIn; self.waitsBeforeSuccess = waitsBeforeSuccess
            self.callbackReached = callback; self.callbackFails = callbackFails
        }
        private var response: OAuthURLResponse {
            .init(status: "ok", url: invalidURL ? "file:///tmp/fixture" : "https://example.invalid/login", state: name, userCode: userCode, flow: flow, expiresIn: expiresIn)
        }
        func getOAuthURL(for provider: AIProvider) async throws -> OAuthURLResponse {
            if holdsStart {
                return await withCheckedContinuation { startWaiter = $0; startReached?.fulfill() }
            }
            startReached?.fulfill(); return response
        }
        func pollOAuthStatus(state: String) async throws -> OAuthStatusResponse {
            pollCount += 1
            if pollFails { pollReached?.fulfill(); throw APIError.httpError(401) }
            if holdsPoll {
                return await withCheckedContinuation { pollWaiter = $0; pollReached?.fulfill() }
            }
            pollReached?.fulfill(); return .init(status: pollCount <= waitsBeforeSuccess ? "wait" : "ok", error: nil)
        }
        func cancelOAuthSession(state: String) async throws -> Bool {
            cancelled.append(state); cancelReached?.fulfill(); return true
        }
        func submitOAuthCallback(provider: AIProvider, redirectURL: String) async throws {
            callbacks.append((provider: provider, redirectURL: redirectURL))
            if callbackReached != nil {
                await withCheckedContinuation { callbackWaiter = $0; callbackReached?.fulfill() }
            }
            if callbackFails { throw APIError.httpError(400) }
        }
        func releaseCallback() { callbackWaiter?.resume(); callbackWaiter = nil }
        func releaseStart() { startWaiter?.resume(returning: response); startWaiter = nil }
        func releasePoll() { pollWaiter?.resume(returning: .init(status: "ok", error: nil)); pollWaiter = nil }
    }

    @MainActor
    func testSuccessfulSessionPublishesThreeStatesAndRefreshesOnce() async {
        let coordinator = CPAOAuthSessionCoordinator(sleep: {})
        let client = Client("success")
        var phases: [OAuthState.OAuthStatus] = []
        var refreshes = 0
        await coordinator.start(provider: .claude, client: client, update: { if let state = $0 { phases.append(state.status) } },
            authorized: { refreshes += 1 })
        XCTAssertEqual(phases, [.waiting, .polling, .success])
        XCTAssertEqual(refreshes, 1)
        let cancelled = await client.cancelled
        XCTAssertTrue(cancelled.isEmpty, "成功完成的登录不能被当成挂起会话取消")
    }

    @MainActor
    func testCancelPollingCallsServerAndDiscardsLateSuccess() async {
        let polled = expectation(description: "旧登录正在轮询")
        let cancelled = expectation(description: "服务端收到取消")
        let client = Client("pending", poll: polled, cancel: cancelled, holdsPoll: true)
        let coordinator = CPAOAuthSessionCoordinator(sleep: {})
        var displayed: OAuthState?
        var refreshes = 0
        let running = Task { await coordinator.start(provider: .claude, client: client, update: { displayed = $0 }, authorized: { refreshes += 1 }) }
        await fulfillment(of: [polled], timeout: 3)
        coordinator.cancel()
        await fulfillment(of: [cancelled], timeout: 3)
        await client.releasePoll()
        await running.value
        XCTAssertNil(displayed)
        XCTAssertEqual(refreshes, 0)
        let states = await client.cancelled
        XCTAssertEqual(states, ["pending"])
    }

    @MainActor
    func testLateStartResponseIsCancelledWithoutOverwritingTheNewSession() async {
        let oldStarted = expectation(description: "旧授权 URL 请求已开始")
        let oldCancelled = expectation(description: "迟到的旧 state 已取消")
        let newPolled = expectation(description: "新会话正在轮询")
        let newCancelled = expectation(description: "新会话测试结束时取消")
        let old = Client("old", start: oldStarted, cancel: oldCancelled, holdsStart: true)
        let fresh = Client("new", poll: newPolled, cancel: newCancelled, holdsPoll: true)
        let coordinator = CPAOAuthSessionCoordinator(sleep: {})
        var displayed: OAuthState?
        var refreshes = 0
        let first = Task { await coordinator.start(provider: .claude, client: old, update: { displayed = $0 }, authorized: { refreshes += 1 }) }
        await fulfillment(of: [oldStarted], timeout: 3)
        let second = Task { await coordinator.start(provider: .codex, client: fresh, update: { displayed = $0 }, authorized: { refreshes += 1 }) }
        await fulfillment(of: [newPolled], timeout: 3)
        await old.releaseStart()
        await first.value
        await fulfillment(of: [oldCancelled], timeout: 3)
        XCTAssertEqual(displayed?.provider, .codex)
        XCTAssertEqual(displayed?.state, "new")
        XCTAssertEqual(refreshes, 0)
        coordinator.cancel()
        await fulfillment(of: [newCancelled], timeout: 3)
        await fresh.releasePoll(); await second.value
        XCTAssertNil(displayed)
    }

    @MainActor
    func testInvalidAuthorizationURLIsNotOpenedAndPendingStateIsCancelled() async {
        let cancelled = expectation(description: "非法 URL 的 state 已清理")
        let client = Client("invalid", cancel: cancelled, invalidURL: true)
        let coordinator = CPAOAuthSessionCoordinator(sleep: {})
        var opened = false
        var displayed: OAuthState?
        await coordinator.start(provider: .claude, client: client, update: { displayed = $0 }, openURL: { _ in opened = true }, authorized: {})
        await fulfillment(of: [cancelled], timeout: 3)
        XCTAssertFalse(opened)
        XCTAssertEqual(displayed?.status, .error)
        let polls = await client.pollCount
        XCTAssertEqual(polls, 0)
    }

    @MainActor
    func testAuthenticationFailureStopsPollingAndCancelsPendingSession() async {
        let cancelled = expectation(description: "鉴权失败后结束挂起会话")
        let client = Client("failed", cancel: cancelled, pollFails: true)
        let coordinator = CPAOAuthSessionCoordinator(sleep: {})
        var displayed: OAuthState?
        await coordinator.start(provider: .claude, client: client, update: { displayed = $0 }, authorized: {})
        await fulfillment(of: [cancelled], timeout: 3)
        let polls = await client.pollCount
        XCTAssertEqual(polls, 1, "不能吞掉 401 后继续轮询到触发 CPA 鉴权封禁")
        XCTAssertEqual(displayed?.status, .error)
    }

    @MainActor
    func testCoordinatorPassesUserCodeToPollingState() async {
        let polled = expectation(description: "会话已进入轮询")
        let client = Client("device-flow", poll: polled, holdsPoll: true, userCode: "WXYZ-5678")
        let coordinator = CPAOAuthSessionCoordinator(sleep: {})
        var displayed: OAuthState?
        let running = Task {
            await coordinator.start(provider: .codex, client: client, update: { displayed = $0 }, authorized: {})
        }
        await fulfillment(of: [polled], timeout: 3)
        XCTAssertEqual(displayed?.status, .polling)
        XCTAssertEqual(displayed?.userCode, "WXYZ-5678")
        XCTAssertTrue(displayed?.isDeviceFlow == true, "旧响应只有 user_code 时也应识别为设备流")
        XCTAssertFalse(displayed?.supportsManualCallback ?? true)
        coordinator.cancel()
        await client.releasePoll()
        await running.value
    }

    func testResolveCallbackURLVariants() {
        // 完整 URL 和参数串均须绑定当前 state，原始授权码沿用实际代理端口。
        let fullURL = "http://localhost:8317/oauth/callback?code=testcode123&state=state456"
        XCTAssertEqual(ManagementAPIClient.resolveCallbackURL(provider: .claude, input: fullURL, state: "state456"), fullURL)
        XCTAssertNil(ManagementAPIClient.resolveCallbackURL(provider: .claude, input: fullURL, state: "different-state"))
        let query = ManagementAPIClient.resolveCallbackURL(provider: .claude, input: "code=authcode789&state=mystate", state: "mystate")
        XCTAssertTrue(query?.contains("code=authcode789&state=mystate") == true)
        let code = ManagementAPIClient.resolveCallbackURL(provider: .claude, input: "singlecode999", state: "session", defaultPort: 9000)
        XCTAssertTrue(code?.contains("localhost:9000/oauth/callback?code=singlecode999&state=session") == true)

        // 4. 空输入返回 nil
        XCTAssertNil(ManagementAPIClient.resolveCallbackURL(provider: .claude, input: "   ", state: "state"))

        // 5. 缺少 state 返回 nil
        XCTAssertNil(ManagementAPIClient.resolveCallbackURL(provider: .claude, input: "singlecode999", state: nil))
    }

    @MainActor
    private final class Clock {
        var instant = ContinuousClock.now
        func advance() { instant = instant.advanced(by: .seconds(2)) }
    }

    @MainActor
    func testDeviceFlowCanAuthorizeAfterTheOldSixtyPollLimit() async {
        let clock = Clock()
        let coordinator = CPAOAuthSessionCoordinator(sleep: { await clock.advance() }, now: { clock.instant })
        let client = Client("long-device", userCode: "DEVICE-CODE", flow: "device", expiresIn: 300, waitsBeforeSuccess: 75)
        var states: [OAuthState] = []
        var refreshed = 0
        await coordinator.start(provider: .grok, client: client, update: { if let state = $0 { states.append(state) } }, authorized: { refreshed += 1 })
        let polls = await client.pollCount
        XCTAssertEqual(polls, 76)
        XCTAssertEqual(states.last?.status, .success)
        XCTAssertEqual(refreshed, 1)
        XCTAssertEqual(Set(states.map(\.sessionID)).count, 1)
        XCTAssertEqual(states[1].userCode, "DEVICE-CODE")
        XCTAssertTrue(states[1].isDeviceFlow)
        XCTAssertFalse(states[1].supportsManualCallback)
    }

    @MainActor
    func testGrokWithoutOptionalFieldsUsesDeviceFlowLifetime() async {
        let clock = Clock()
        let coordinator = CPAOAuthSessionCoordinator(sleep: { await clock.advance() }, now: { clock.instant })
        let client = Client("legacy-device", waitsBeforeSuccess: 75)
        var displayed: OAuthState?
        await coordinator.start(provider: .grok, client: client, update: { displayed = $0 }, authorized: {})
        XCTAssertEqual(displayed?.status, .success)
    }

    @MainActor
    func testServerExpiryCancelsOnlyThePendingSession() async {
        let cancelled = expectation(description: "有效期届满取消设备流")
        let clock = Clock()
        let coordinator = CPAOAuthSessionCoordinator(sleep: { await clock.advance() }, now: { clock.instant })
        let client = Client("expired", cancel: cancelled, flow: "device", expiresIn: 5, waitsBeforeSuccess: 100)
        var displayed: OAuthState?
        var refreshed = false
        await coordinator.start(provider: .grok, client: client, update: { displayed = $0 }, authorized: { refreshed = true })
        await fulfillment(of: [cancelled], timeout: 3)
        let polls = await client.pollCount
        XCTAssertEqual(polls, 2)
        XCTAssertEqual(displayed?.status, .error)
        XCTAssertFalse(refreshed)
    }

    @MainActor
    func testCallbackRejectsWrongProviderSessionAndStateAndKeepsOpaqueCode() async throws {
        let polled = expectation(description: "浏览器流挂起")
        let client = Client("bound-state", poll: polled, holdsPoll: true)
        let coordinator = CPAOAuthSessionCoordinator(sleep: {})
        var displayed: OAuthState?
        let running = Task { await coordinator.start(provider: .claude, client: client, update: { displayed = $0 }, authorized: {}) }
        await fulfillment(of: [polled], timeout: 3)
        let sessionID = try XCTUnwrap(displayed?.sessionID)
        let cancelledSubmission = Task {
            try await coordinator.submitCallback("code", provider: .claude, sessionID: sessionID, defaultPort: 8317)
        }
        cancelledSubmission.cancel()
        do { try await cancelledSubmission.value; XCTFail("已取消的提交必须拒绝执行") }
        catch is CancellationError { }
        XCTAssertEqual(displayed?.status, .polling, "取消提交 Task 不应取消整个正在进行的授权会话")
        for (provider, id, input) in [(AIProvider.codex, sessionID, "code"), (.claude, UUID(), "code"),
            (.claude, sessionID, "code=other&state=another-pending-session")] {
            do {
                try await coordinator.submitCallback(input, provider: provider, sessionID: id, defaultPort: 8317)
                XCTFail("不应提交其它会话的回调")
            } catch { }
        }
        let rejected = await client.callbacks
        XCTAssertTrue(rejected.isEmpty)
        try await coordinator.submitCallback("code: A+B/C==", provider: .claude, sessionID: sessionID, defaultPort: 9000)
        XCTAssertEqual(displayed?.callbackStatus, .submitted)
        let callbacks = await client.callbacks
        XCTAssertEqual(callbacks.count, 1)
        XCTAssertEqual(callbacks.first?.provider, .claude)
        XCTAssertTrue(callbacks.first?.redirectURL.contains("code=A%2BB/C%3D%3D") == true)
        do {
            try await coordinator.submitCallback("again", provider: .claude, sessionID: sessionID, defaultPort: 8317)
            XCTFail("等待轮询完成时不能重复提交")
        } catch { }
        coordinator.cancel(); await client.releasePoll(); await running.value
    }

    @MainActor
    func testDeviceFlowNeverPostsManualCallback() async throws {
        let polled = expectation(description: "设备授权挂起")
        let client = Client("device", poll: polled, holdsPoll: true, flow: "device", expiresIn: 300)
        let coordinator = CPAOAuthSessionCoordinator(sleep: {})
        var displayed: OAuthState?
        let running = Task { await coordinator.start(provider: .devin, client: client, update: { displayed = $0 }, authorized: {}) }
        await fulfillment(of: [polled], timeout: 3)
        XCTAssertFalse(displayed?.supportsManualCallback ?? true)
        do {
            try await coordinator.submitCallback("code", provider: .devin, sessionID: try XCTUnwrap(displayed?.sessionID), defaultPort: 8317)
            XCTFail("设备流不能提交浏览器回调")
        } catch { }
        let callbacks = await client.callbacks
        XCTAssertTrue(callbacks.isEmpty)
        coordinator.cancel(); await client.releasePoll(); await running.value
    }

    @MainActor
    func testLateCallbackSuccessAndFailureCannotChangeSameProviderRetry() async throws {
        // 分别覆盖迟到成功与迟到错误；新旧都是 Claude，不能只靠 provider 判断身份。
        for fails in [false, true] {
            let oldPolled = expectation(description: "旧会话轮询")
            let callback = expectation(description: "旧回调挂起")
            let freshPolled = expectation(description: "重试会话轮询")
            let old = Client("old", poll: oldPolled, holdsPoll: true, callback: callback, callbackFails: fails)
            let fresh = Client("fresh", poll: freshPolled, holdsPoll: true)
            let coordinator = CPAOAuthSessionCoordinator(sleep: {})
            var displayed: OAuthState?
            let first = Task { await coordinator.start(provider: .claude, client: old, update: { displayed = $0 }, authorized: {}) }
            await fulfillment(of: [oldPolled], timeout: 3)
            let oldID = try XCTUnwrap(displayed?.sessionID)
            let submission = Task { try await coordinator.submitCallback("code", provider: .claude, sessionID: oldID, defaultPort: 8317) }
            await fulfillment(of: [callback], timeout: 3)
            XCTAssertEqual(displayed?.callbackStatus, .submitting)
            let second = Task { await coordinator.start(provider: .claude, client: fresh, update: { displayed = $0 }, authorized: {}) }
            await fulfillment(of: [freshPolled], timeout: 3)
            await old.releaseCallback()
            try await submission.value
            XCTAssertEqual(displayed?.state, "fresh")
            XCTAssertNotEqual(displayed?.sessionID, oldID)
            XCTAssertEqual(displayed?.callbackStatus, .idle)
            await old.releasePoll(); await first.value
            coordinator.cancel(); await fresh.releasePoll(); await second.value
        }
    }

    @MainActor
    func testChangedRuntimeContextRejectsCallbackAndLatePollSuccess() async throws {
        let polled = expectation(description: "旧运行上下文轮询")
        let client = Client("old-context", poll: polled, holdsPoll: true)
        let coordinator = CPAOAuthSessionCoordinator(sleep: {})
        var contextIsCurrent = true
        var displayed: OAuthState?
        var refreshed = false
        let running = Task {
            await coordinator.start(provider: .claude, client: client, contextIsCurrent: { contextIsCurrent },
                update: { displayed = $0 }, authorized: { refreshed = true })
        }
        await fulfillment(of: [polled], timeout: 3)
        contextIsCurrent = false
        do {
            try await coordinator.submitCallback("code", provider: .claude, sessionID: try XCTUnwrap(displayed?.sessionID), defaultPort: 8317)
            XCTFail("运行上下文变更后不应提交")
        } catch { }
        await client.releasePoll(); await running.value
        XCTAssertFalse(refreshed)
        XCTAssertNil(displayed, "自动重启等上下文变化必须结束旧等待状态，让用户可以重试")
        let callbacks = await client.callbacks
        XCTAssertTrue(callbacks.isEmpty)
        coordinator.cancel()
    }

    @MainActor
    func testRuntimeChangeWhilePollingClearsWaitingWithoutManualSubmission() async {
        let polled = expectation(description: "等待轮询响应")
        let cancelled = expectation(description: "自动重启后清理旧 state")
        let client = Client("poll-context", poll: polled, cancel: cancelled, holdsPoll: true)
        let coordinator = CPAOAuthSessionCoordinator(sleep: {})
        var contextIsCurrent = true
        var displayed: OAuthState?
        var refreshed = false
        let running = Task {
            await coordinator.start(provider: .claude, client: client, contextIsCurrent: { contextIsCurrent },
                update: { displayed = $0 }, authorized: { refreshed = true })
        }
        await fulfillment(of: [polled], timeout: 3)
        contextIsCurrent = false
        await client.releasePoll(); await running.value
        await fulfillment(of: [cancelled], timeout: 3)
        XCTAssertNil(displayed, "不点击回调也必须结束旧等待状态")
        XCTAssertFalse(refreshed)
    }

    @MainActor
    func testBrowserWithoutExpiryKeepsExistingTwoMinuteTimeout() async {
        let clock = Clock()
        let cancelled = expectation(description: "旧浏览器流按原默认时间结束")
        let coordinator = CPAOAuthSessionCoordinator(sleep: { await clock.advance() }, now: { clock.instant })
        let client = Client("browser-default", cancel: cancelled, waitsBeforeSuccess: 75)
        var displayed: OAuthState?
        await coordinator.start(provider: .claude, client: client, update: { displayed = $0 }, authorized: {})
        await fulfillment(of: [cancelled], timeout: 3)
        XCTAssertEqual(displayed?.status, .error)
        XCTAssertFalse(displayed?.isDeviceFlow ?? true)
        let polls = await client.pollCount
        XCTAssertLessThan(polls, 60)
    }

    @MainActor
    func testRuntimeChangeWhileURLIsPendingClearsWaitingAndCancelsLateState() async {
        let started = expectation(description: "授权 URL 挂起")
        let cancelled = expectation(description: "迟到 state 已取消")
        let client = Client("late-context", start: started, cancel: cancelled, holdsStart: true)
        let coordinator = CPAOAuthSessionCoordinator(sleep: {})
        var contextIsCurrent = true
        var displayed: OAuthState?
        var opened = false
        let running = Task {
            await coordinator.start(provider: .claude, client: client, contextIsCurrent: { contextIsCurrent },
                update: { displayed = $0 }, openURL: { _ in opened = true }, authorized: {})
        }
        await fulfillment(of: [started], timeout: 3)
        contextIsCurrent = false
        await client.releaseStart(); await running.value
        await fulfillment(of: [cancelled], timeout: 3)
        XCTAssertNil(displayed)
        XCTAssertFalse(opened)
    }

    func testCallbackParserPreservesCodesAndRejectsAmbiguousState() throws {
        for input in ["code: A+B/C==", "A+B/C==", "code=A%2BB%2FC%3D%3D&state=s%2Bt",
                      "http://localhost/callback?code=A%2BB%2FC%3D%3D&state=s%2Bt"] {
            let resolved = try XCTUnwrap(ManagementAPIClient.resolveCallbackURL(provider: .claude, input: input, state: "s+t"))
            // 模拟 Go application/x-www-form-urlencoded 对 + 的规则，再检查不透明值。
            let formSafe = resolved.replacingOccurrences(of: "+", with: " ")
            let items = try XCTUnwrap(URLComponents(string: formSafe)?.queryItems)
            XCTAssertEqual(items.first { $0.name == "code" }?.value, "A+B/C==")
            XCTAssertEqual(items.first { $0.name == "state" }?.value, "s+t")
        }
        for input in ["code=c&state=other", "code=c&state=s&state=s", "code=c&code=d&state=s",
                      "http://localhost/callback?code=c", "http://localhost/callback?state=s", "file:///tmp/callback?code=c&state=s"] {
            XCTAssertNil(ManagementAPIClient.resolveCallbackURL(provider: .claude, input: input, state: "s"), input)
        }
        let error = try XCTUnwrap(ManagementAPIClient.resolveCallbackURL(provider: .devin,
            input: "http://localhost/callback?error=access_denied&error_description=Cancelled&state=s", state: "s"))
        XCTAssertTrue(error.contains("error=access_denied"))
    }

    func testManualAuthCapabilityDependsOnModeWithoutChangingQuotaSupport() {
        for provider in [AIProvider.grok, .devin] {
            XCTAssertTrue(provider.supportsManualAuth(in: .localProxy))
            XCTAssertFalse(provider.supportsManualAuth(in: .monitor))
            XCTAssertTrue(provider.supportsQuotaOnlyMode)
        }
        XCTAssertTrue(AIProvider.claude.supportsManualAuth(in: .monitor))
        XCTAssertTrue(AIProvider.codex.supportsManualAuth(in: .monitor))
    }

    func testCPAOAuthProviderKeyMapping() {
        XCTAssertEqual(ManagementAPIClient.cpaOAuthProviderKey(for: .grok), "xai")
        XCTAssertEqual(ManagementAPIClient.cpaOAuthProviderKey(for: .claude), "claude")
        XCTAssertEqual(ManagementAPIClient.cpaOAuthProviderKey(for: .codex), "codex")
        XCTAssertEqual(ManagementAPIClient.cpaOAuthProviderKey(for: .devin), "devin")
    }
}
