import Foundation
import XCTest
@testable import QuotioPlus

/// 使用生产协调器、保险库和元数据存储复现迟到提交，所有凭据与账号均为合成夹具。
/// token 通过注入 URLSession 的 URLProtocol 截获，浏览器替换为内存回调；不授权真实账号或读写钥匙串。
@MainActor
final class MonitorClaudeOAuthIsolationTests: XCTestCase {
    nonisolated private static let token = #"{"access_token":"fixture-token","refresh_token":"fixture-refresh","expires_in":3600,"account":{"email_address":"fixture@example.invalid","uuid":"fixture-account"}}"#

    private struct Fixture {
        let coordinator: MonitorOAuthCoordinator
        let metadata: MonitorMetadataStore
        let vault: MonitorCredentialVault
        let backend: MemoryBackend
        let http: LifecycleHTTPState
    }

    /// 锁只保护测试内存字典；可在一次无世代保存中阻塞保险库，以验证排队中的旧授权不能越过取消。
    private final class MemoryBackend: @unchecked Sendable {
        private let lock = NSLock()
        private var values: [String: Data] = [:]
        private var nextGate: SaveGate?
        var count: Int { lock.withLock { values.count } }
        func blockNextSave(_ gate: SaveGate) { lock.withLock { nextGate = gate } }
        func read(_ key: String) -> Data? { lock.withLock { values[key] } }
        func save(_ data: Data, _ key: String) -> Bool {
            let gate = lock.withLock { let gate = nextGate; nextGate = nil; return gate }
            gate?.wait()
            return lock.withLock { values[key] = data; return true }
        }
        func replace(_ data: Data, _ key: String, _ expected: String) -> Bool {
            lock.withLock {
                guard let old = values[key], MonitorIdentity.fingerprint(old.base64EncodedString()) == expected else { return false }
                values[key] = data
                return true
            }
        }
        func delete(_ key: String) { lock.withLock { _ = values.removeValue(forKey: key) } }
        var adapter: MonitorCredentialVault.Backend {
            .init(read: { self.read($0) }, save: { self.save($0, $1) },
                  compareAndSwap: { self.replace($0, $1, $2) }, delete: { self.delete($0) })
        }
    }

    private final class SaveGate: @unchecked Sendable {
        let entered: XCTestExpectation
        private let condition = NSCondition()
        private var released = false
        init(_ entered: XCTestExpectation) { self.entered = entered }
        func wait() {
            entered.fulfill()
            condition.lock()
            while !released { condition.wait() }
            condition.unlock()
        }
        func release() {
            condition.lock(); released = true; condition.broadcast(); condition.unlock()
        }
    }

    private func fixture(_ response: @escaping @Sendable (URLRequest, Int) -> LifecycleHTTPState.Response) throws -> Fixture {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let metadata = MonitorMetadataStore(url: directory.appendingPathComponent("accounts.json"))
        let backend = MemoryBackend()
        let vault = MonitorCredentialVault(metadata: metadata, backend: backend.adapter)
        let http = LifecycleHTTPState(response: response)
        // 保留生产 token URL，通过仅属于此测试会话的协议截获；未注册请求会直接失败，不回落真实网络。
        LifecycleHTTPProtocol.register(http, host: "platform.claude.com")
        LifecycleHTTPProtocol.register(http, host: "github.com")
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [LifecycleHTTPProtocol.self]
        let session = URLSession(configuration: configuration)
        let coordinator = MonitorOAuthCoordinator(session: session, claudeVault: vault, openClaudeURL: { _ in true })
        addTeardownBlock {
            await coordinator.cancel()
            session.invalidateAndCancel()
            LifecycleHTTPProtocol.remove(host: "platform.claude.com")
            LifecycleHTTPProtocol.remove(host: "github.com")
            try? FileManager.default.removeItem(at: directory)
        }
        return Fixture(coordinator: coordinator, metadata: metadata, vault: vault, backend: backend, http: http)
    }

    private func model(_ coordinator: MonitorOAuthCoordinator) throws -> QuotaViewModel {
        let name = "quotio-monitor-claude-isolation-" + UUID().uuidString
        let defaults = try XCTUnwrap(UserDefaults(suiteName: name))
        defaults.set(OperatingMode.monitor.rawValue, forKey: "operatingMode")
        addTeardownBlock { defaults.removePersistentDomain(forName: name) }
        return QuotaViewModel(
            directAuthService: DirectAuthFileService(authDirectory: FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)),
            startsBackgroundServices: false, modeManager: OperatingModeManager(defaults: defaults),
            menuBarSettings: MenuBarSettingsManager(defaults: defaults), refreshSettings: RefreshSettingsManager(defaults: defaults),
            warmupSettings: WarmupSettingsManager(defaults: defaults),
            notificationManager: NotificationManager(testDefaults: defaults, notificationSink: { _ in }), monitorOAuth: coordinator)
    }

    func testCurrentSessionPreservesTokenContractAndPersistsCredential() async throws {
        let fixture = try fixture { request, _ in
            XCTAssertEqual(request.url?.absoluteString, "https://platform.claude.com/v1/oauth/token")
            XCTAssertEqual(request.httpMethod, "POST")
            XCTAssertEqual(request.value(forHTTPHeaderField: "Content-Type"), "application/json")
            return .reply(Self.token)
        }
        let pending = try await fixture.coordinator.beginClaudeLogin()
        let account = try await fixture.coordinator.completeClaudeLogin(code: "fixture-code#" + pending.state)
        let request = try XCTUnwrap(fixture.http.requests.first)
        let body = try XCTUnwrap(try JSONSerialization.jsonObject(with: XCTUnwrap(request.body)) as? [String: Any])
        XCTAssertEqual(body["state"] as? String, pending.state)
        XCTAssertEqual(body["code"] as? String, "fixture-code")
        XCTAssertEqual(body["grant_type"] as? String, "authorization_code")
        XCTAssertEqual(body["redirect_uri"] as? String, "https://platform.claude.com/oauth/code/callback")
        XCTAssertFalse(try XCTUnwrap(body["code_verifier"] as? String).isEmpty)
        let stored = await fixture.vault.credential(for: account.id)
        let accounts = await fixture.metadata.accounts()
        XCTAssertEqual(stored?.accessToken, "fixture-token")
        XCTAssertEqual(stored?.refreshToken, "fixture-refresh")
        XCTAssertNotNil(stored?.expiresAt)
        XCTAssertEqual(accounts.map(\.id), [account.id])
        XCTAssertEqual(fixture.backend.count, 1)
    }

    func testCancelRejectsLateTokenWithoutSavingOrPublishing() async throws {
        let gate = LifecycleHTTPResponseGate(), started = expectation(description: "token 交换已挂起")
        let fixture = try fixture { _, _ in started.fulfill(); return .deferred(gate) }
        let model = try model(fixture.coordinator)
        await model.startOAuth(for: .claude)
        let exchange = Task { await model.completeMonitorOAuthCode("fixture-code", provider: .claude) }
        await fulfillment(of: [started], timeout: 3)
        model.cancelOAuth()
        XCTAssertNil(model.oauthState)
        gate.release(.reply(Self.token))
        await exchange.value
        let accounts = await fixture.metadata.accounts()
        XCTAssertEqual(fixture.backend.count, 0)
        XCTAssertTrue(accounts.isEmpty)
        XCTAssertNil(model.oauthState, "旧成功不能在取消后重新发布状态")
    }

    func testCallerTaskCancellationDoesNotPublishAuthorizationError() async throws {
        let started = expectation(description: "可取消的网络请求已开始")
        let fixture = try fixture { _, _ in started.fulfill(); return .hold }
        let model = try model(fixture.coordinator)
        await model.startOAuth(for: .claude)
        let exchange = Task { await model.completeMonitorOAuthCode("fixture-code", provider: .claude) }
        await fulfillment(of: [started], timeout: 3)
        exchange.cancel()
        await exchange.value
        XCTAssertNil(model.oauthState, "URLSession 取消不应被显示成授权错误")
        XCTAssertEqual(fixture.backend.count, 0)
    }

    func testNewClaudeSessionSurvivesLateSuccessAndFailure() async throws {
        for late in [LifecycleHTTPState.Response.reply(Self.token), .replyStatus(#"{"error":"fixture-old-error"}"#, 400)] {
            let gate = LifecycleHTTPResponseGate(), started = expectation(description: "旧 token 交换已挂起")
            let fixture = try fixture { _, count in
                if count == 1 { started.fulfill(); return .deferred(gate) }
                return .reply(Self.token)
            }
            let model = try model(fixture.coordinator)
            await model.startOAuth(for: .claude)
            let old = Task { await model.completeMonitorOAuthCode("old-code", provider: .claude) }
            await fulfillment(of: [started], timeout: 3)
            await model.startOAuth(for: .claude)
            let replacement = try XCTUnwrap(model.oauthState)
            gate.release(late)
            await old.value
            XCTAssertEqual(model.oauthState?.sessionID, replacement.sessionID)
            XCTAssertEqual(model.oauthState?.state, replacement.state)
            XCTAssertEqual(model.oauthState?.status, .polling)
            XCTAssertEqual(fixture.backend.count, 0, "旧响应不能先写保险库再只丢弃 UI")
            // 真正完成新 pending，证明旧 defer 没有清空它；不用 VM 成功入口，避免触发真实额度发现。
            _ = try await fixture.coordinator.completeClaudeLogin(code: "new-code", expectedState: replacement.state)
            XCTAssertEqual(fixture.backend.count, 1)
            XCTAssertEqual(fixture.http.requestCount, 2)
        }
    }

    func testLateCancelCleanupCannotClearNewPending() async throws {
        let fixture = try fixture { _, _ in .reply(Self.token) }
        _ = try await fixture.coordinator.beginClaudeLogin()
        let cutoff = fixture.coordinator.advanceClaudeSession()
        let replacement = try await fixture.coordinator.beginClaudeLogin()
        await fixture.coordinator.cancel(throughClaudeRevision: cutoff)
        _ = try await fixture.coordinator.completeClaudeLogin(code: "new-code", expectedState: replacement.state)
        XCTAssertEqual(fixture.backend.count, 1)
    }

    func testLateCancelStopsOlderDeviceFlowWithoutClearingNewClaudePending() async throws {
        let started = expectation(description: "旧设备授权已挂起"), finished = expectation(description: "旧设备授权已取消")
        let fixture = try fixture { request, _ in
            if request.url?.host == "github.com" { started.fulfill(); return .hold }
            return .reply(Self.token)
        }
        let model = try model(fixture.coordinator)
        var oldCompleted = false
        let old = Task { await model.startOAuth(for: .copilot); oldCompleted = true; finished.fulfill() }
        await fulfillment(of: [started], timeout: 3)
        // 精确模拟 VM 同步取消后，actor 清理晚于新 Claude begin 才执行的次序。
        let cutoff = fixture.coordinator.advanceClaudeSession()
        await model.startOAuth(for: .claude)
        let replacement = try XCTUnwrap(model.oauthState)
        await fixture.coordinator.cancel(throughClaudeRevision: cutoff)
        await fulfillment(of: [finished], timeout: 3)
        // 即使用例失败也释放所有原任务，避免让未响应取消的夹具挂住测试进程。
        if !oldCompleted { await fixture.coordinator.cancel() }
        await old.value
        XCTAssertEqual(model.oauthState?.sessionID, replacement.sessionID)
        XCTAssertEqual(model.oauthState?.status, .polling)
        _ = try await fixture.coordinator.completeClaudeLogin(code: "new-code", expectedState: replacement.state)
        XCTAssertEqual(fixture.backend.count, 1)
    }

    func testStaleUIStateCannotConsumeCurrentPending() async throws {
        let fixture = try fixture { _, _ in .reply(Self.token) }
        let current = try await fixture.coordinator.beginClaudeLogin()
        do {
            _ = try await fixture.coordinator.completeClaudeLogin(code: "old-code", expectedState: "old-state")
            XCTFail("旧 UI 不能使用新一轮 verifier")
        } catch { XCTAssertTrue(error is CancellationError) }
        XCTAssertEqual(fixture.http.requestCount, 0)
        _ = try await fixture.coordinator.completeClaudeLogin(code: "new-code", expectedState: current.state)
        XCTAssertEqual(fixture.backend.count, 1)
    }

    func testDuplicateUICompletionDoesNotSendSecondRequest() async throws {
        let gate = LifecycleHTTPResponseGate(), started = expectation(description: "首个提交已挂起")
        let fixture = try fixture { _, _ in started.fulfill(); return .deferred(gate) }
        let model = try model(fixture.coordinator)
        await model.startOAuth(for: .claude)
        let exchange = Task { await model.completeMonitorOAuthCode("first", provider: .claude) }
        await fulfillment(of: [started], timeout: 3)
        await model.completeMonitorOAuthCode("duplicate", provider: .claude)
        XCTAssertEqual(fixture.http.requestCount, 1)
        model.cancelOAuth()
        gate.release(.reply(Self.token))
        await exchange.value
        XCTAssertEqual(fixture.backend.count, 0)
    }

    func testQueuedVaultWriteRejectsSessionInvalidatedWhileWaiting() async throws {
        let fixture = try fixture { _, _ in .reply(Self.token) }
        let entered = expectation(description: "无世代保存暂时占用保险库"), queued = expectation(description: "授权保存准备进入保险库")
        let gate = SaveGate(entered)
        fixture.backend.blockNextSave(gate)
        defer { gate.release() }
        let credential = MonitorOAuthCredential(accessToken: "fixture", refreshToken: nil, idToken: nil, accountID: nil, expiresAt: nil, extra: [:])
        let first = MonitorAccount.make(provider: .claude, accountKey: "first", source: .quotioKeychain, credentialReference: "keychain", canDelete: true)
        let expired = MonitorAccount.make(provider: .claude, accountKey: "expired", source: .quotioKeychain, credentialReference: "keychain", canDelete: true)
        let occupying = Task { try await fixture.vault.save(credential, metadata: first) }
        await fulfillment(of: [entered], timeout: 3)
        let state = MonitorStateRevision(), revision = state.advance()
        let pending = Task {
            queued.fulfill()
            try await fixture.vault.save(credential, metadata: expired, revision: revision, state: state)
        }
        await fulfillment(of: [queued], timeout: 3)
        state.advance()
        gate.release()
        try await occupying.value
        do { try await pending.value; XCTFail("排队期间已取消的授权不能在保险库恢复后保存") }
        catch { XCTAssertTrue(error is CancellationError) }
        let accounts = await fixture.metadata.accounts()
        XCTAssertEqual(fixture.backend.count, 1)
        XCTAssertNil(fixture.backend.read(expired.id))
        XCTAssertEqual(accounts.map(\.id), [first.id])
    }

    func testMetadataRejectsExpiredSessionWithoutChangingExistingAccounts() async throws {
        let fixture = try fixture { _, _ in .reply(Self.token) }
        let account = MonitorAccount.make(provider: .claude, accountKey: "fixture", source: .quotioKeychain, credentialReference: "keychain", canDelete: true)
        let state = MonitorStateRevision(), revision = state.advance()
        state.advance()
        do { try await fixture.metadata.saveAccount(account, revision: revision, state: state); XCTFail("失效授权不能补写元数据") }
        catch { XCTAssertTrue(error is CancellationError) }
        let accounts = await fixture.metadata.accounts()
        XCTAssertTrue(accounts.isEmpty)
    }

    func testNativeCodeStateMismatchRemainsRejected() async throws {
        let fixture = try fixture { _, _ in .reply(Self.token) }
        _ = try await fixture.coordinator.beginClaudeLogin()
        do {
            _ = try await fixture.coordinator.completeClaudeLogin(code: "fixture-code#wrong-state")
            XCTFail("原 code#state 校验仍应拒绝不匹配回调")
        } catch MonitorOAuthError.stateMismatch { }
        XCTAssertEqual(fixture.http.requestCount, 0)
        XCTAssertEqual(fixture.backend.count, 0)
    }
}
