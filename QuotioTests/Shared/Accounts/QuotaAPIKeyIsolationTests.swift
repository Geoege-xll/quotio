import XCTest
@testable import QuotioPlus

/// 通过可显式释放的离线响应复现迟到读写；不依赖真实网络、计时碰运气或关闭请求来掩盖提交竞态。
@MainActor
final class QuotaAPIKeyIsolationTests: XCTestCase {
    private func fixture() throws -> QuotaViewModel {
        let suite = "quotio-api-key-isolation-" + UUID().uuidString
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defaults.set(OperatingMode.localProxy.rawValue, forKey: "operatingMode")
        let notifications = NotificationManager(testDefaults: defaults, notificationSink: { _ in })
        let model = QuotaViewModel(
            directAuthService: DirectAuthFileService(authDirectory: FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)),
            startsBackgroundServices: false, modeManager: OperatingModeManager(defaults: defaults),
            menuBarSettings: MenuBarSettingsManager(defaults: defaults), refreshSettings: RefreshSettingsManager(defaults: defaults),
            warmupSettings: WarmupSettingsManager(defaults: defaults), notificationManager: notifications
        )
        addTeardownBlock { @MainActor in defaults.removePersistentDomain(forName: suite) }
        return model
    }

    private func client(_ response: @escaping @Sendable (URLRequest, Int) -> LifecycleHTTPState.Response)
        -> (ManagementAPIClient, LifecycleHTTPState) {
        let host = UUID().uuidString.lowercased() + ".invalid"
        let state = LifecycleHTTPState(response: response)
        LifecycleHTTPProtocol.register(state, host: host)
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [LifecycleHTTPProtocol.self]
        let client = ManagementAPIClient(baseURL: "https://" + host + ManagementAPIClient.managementPath,
                                         authKey: "fixture", configuration: configuration)
        addTeardownBlock { await client.invalidate(); LifecycleHTTPProtocol.remove(host: host) }
        return (client, state)
    }

    /// 新读先完成之后，旧成功与旧失败都不能覆盖列表或污染当前错误。
    func testNewerReadSupersedesLateSuccessAndFailure() async throws {
        for late in [LifecycleHTTPState.Response.reply(#"["old"]"#), .replyStatus("{}", 401)] {
            let model = try fixture(), gate = LifecycleHTTPResponseGate()
            let started = expectation(description: "旧列表读取已挂起")
            let (client, _) = client { _, count in
                if count == 1 { started.fulfill(); return .deferred(gate) }
                return .reply(#"["current"]"#)
            }
            model.setAuthImportClientForTesting(client)
            let pending = Task { await model.fetchAPIKeys() }
            await fulfillment(of: [started], timeout: 3)
            await model.fetchAPIKeys()
            model.errorMessage = "current message"
            gate.release(late)
            await pending.value
            XCTAssertEqual(model.apiKeys, ["current"])
            XCTAssertEqual(model.errorMessage, "current message")
        }
    }

    func testConfirmedEditInvalidatesEarlierListSuccessAndFailure() async throws {
        for late in [LifecycleHTTPState.Response.reply(#"["base"]"#), .replyStatus("{}", 401)] {
            let model = try fixture(), gate = LifecycleHTTPResponseGate()
            let started = expectation(description: "编辑前的列表已挂起")
            let (client, _) = client { request, count in
                if count == 1 { started.fulfill(); return .deferred(gate) }
                return request.httpMethod == "GET" ? .reply(#"["base"]"#) : .reply(#"{"status":"ok","config-version":8}"#)
            }
            model.setAuthImportClientForTesting(client)
            model.apiKeys = ["base"]
            let pending = Task { await model.fetchAPIKeys() }
            await fulfillment(of: [started], timeout: 3)
            let added = await model.addAPIKey("new")
            XCTAssertTrue(added)
            gate.release(late)
            await pending.value
            XCTAssertEqual(model.apiKeys, ["base", "new"])
            XCTAssertNil(model.errorMessage)
        }
    }

    func testReadDuringPendingEditDoesNotIssueOrSupersedeMutation() async throws {
        let model = try fixture(), gate = LifecycleHTTPResponseGate()
        let started = expectation(description: "编辑等待服务端列表")
        let (client, state) = client { _, count in
            if count == 1 { started.fulfill(); return .deferred(gate) }
            return .reply(#"{"status":"ok","config-version":8}"#)
        }
        model.setAuthImportClientForTesting(client)
        model.apiKeys = ["base"]
        let pending = Task { await model.addAPIKey("new") }
        await fulfillment(of: [started], timeout: 3)
        await model.fetchAPIKeys()
        XCTAssertEqual(state.requestCount, 1)
        gate.release(.reply(#"["base"]"#))
        let added = await pending.value
        XCTAssertTrue(added)
        XCTAssertEqual(model.apiKeys, ["base", "new"])
        XCTAssertFalse(model.isMutatingAPIKeys)
    }

    /// 旧客户端在新编辑开始后返回：既不能关闭旧草稿，也不能由旧 defer 解锁新编辑。
    func testReplacedClientCannotCommitOrReleaseNewMutation() async throws {
        for late in [LifecycleHTTPState.Response.reply(#"{"status":"ok","config-version":8}"#), .replyStatus("{}", 401)] {
            let model = try fixture(), oldGate = LifecycleHTTPResponseGate(), newGate = LifecycleHTTPResponseGate()
            let oldStarted = expectation(description: "旧编辑等待写入确认")
            let newStarted = expectation(description: "新编辑等待写入确认")
            let (oldClient, _) = client { request, _ in
                if request.httpMethod == "GET" { return .reply(#"["base"]"#) }
                oldStarted.fulfill(); return .deferred(oldGate)
            }
            let (newClient, _) = client { request, _ in
                if request.httpMethod == "GET" { return .reply(#"["base"]"#) }
                newStarted.fulfill(); return .deferred(newGate)
            }
            model.apiKeys = ["base"]
            model.setAuthImportClientForTesting(oldClient)
            let oldEdit = Task { await model.addAPIKey("old") }
            await fulfillment(of: [oldStarted], timeout: 3)
            model.setAuthImportClientForTesting(newClient)
            XCTAssertFalse(model.isMutatingAPIKeys)
            let newEdit = Task { await model.addAPIKey("new") }
            await fulfillment(of: [newStarted], timeout: 3)
            model.errorMessage = "new session message"
            oldGate.release(late)
            let oldResult = await oldEdit.value
            XCTAssertFalse(oldResult)
            XCTAssertEqual(model.apiKeys, ["base"])
            XCTAssertEqual(model.errorMessage, "new session message")
            XCTAssertTrue(model.isMutatingAPIKeys, "旧 defer 不能释放新编辑的互斥")
            newGate.release(.reply(#"{"status":"ok","config-version":8}"#))
            let newResult = await newEdit.value
            XCTAssertTrue(newResult)
            XCTAssertEqual(model.apiKeys, ["base", "new"])
            XCTAssertFalse(model.isMutatingAPIKeys)
            XCTAssertNil(model.errorMessage)
        }
    }

    func testAllMutationsRejectResultsAfterModeChanges() async throws {
        for operation in ["add", "update", "delete"] {
            let model = try fixture(), gate = LifecycleHTTPResponseGate()
            let started = expectation(description: operation + " 等待确认")
            let (client, _) = client { request, _ in
                if request.httpMethod == "GET" { return .reply(#"["base"]"#) }
                started.fulfill(); return .deferred(gate)
            }
            model.setAuthImportClientForTesting(client)
            model.apiKeys = ["base"]
            let pending = Task {
                switch operation {
                case "add": return await model.addAPIKey("new")
                case "update": return await model.updateAPIKey(old: "base", new: "new")
                default: return await model.deleteAPIKey("base")
                }
            }
            await fulfillment(of: [started], timeout: 3)
            model.modeManager.setMode(.monitor)
            model.errorMessage = "monitor message"
            gate.release(.reply(#"{"status":"ok","config-version":8}"#))
            let accepted = await pending.value
            XCTAssertFalse(accepted)
            XCTAssertEqual(model.apiKeys, ["base"])
            XCTAssertEqual(model.errorMessage, "monitor message")
            XCTAssertFalse(model.isMutatingAPIKeys)
        }
    }

    func testRuntimeChangeAndCancellationRejectLateRead() async throws {
        let manager = CLIProxyManager.shared, originalStatus = manager.proxyStatus, originalSession = manager.runtimeSessionID
        defer { manager.setRuntimeStateForTesting(running: originalStatus.running, sessionID: originalSession) }
        for cancel in [false, true] {
            let model = try fixture(), gate = LifecycleHTTPResponseGate()
            let started = expectation(description: "等待读取后切换会话或取消")
            let (client, _) = client { _, _ in started.fulfill(); return .deferred(gate) }
            model.setAuthImportClientForTesting(client)
            model.apiKeys = ["current"]
            let pending = Task { await model.fetchAPIKeys() }
            await fulfillment(of: [started], timeout: 3)
            if cancel { pending.cancel() }
            else { manager.setRuntimeStateForTesting(running: originalStatus.running, sessionID: UUID()) }
            gate.release(.reply(#"["late"]"#))
            await pending.value
            XCTAssertEqual(model.apiKeys, ["current"])
            XCTAssertNil(model.errorMessage)
        }
    }

    /// 经过真实 refreshData 入口证明后台路径也复用主类令牌，不能只修复页面的 fetchAPIKeys。
    func testBackgroundDirectoryRefreshCannotOverwriteConfirmedEdit() async throws {
        let model = try fixture(), gate = LifecycleHTTPResponseGate(), manager = model.proxyManager
        let originalStatus = manager.proxyStatus, originalSession = manager.runtimeSessionID
        defer { manager.setRuntimeStateForTesting(running: originalStatus.running, sessionID: originalSession) }
        manager.setRuntimeStateForTesting(running: true, sessionID: UUID())
        let started = expectation(description: "后台密钥读取已挂起")
        let (client, _) = client { request, count in
            if request.url!.path.hasSuffix("/credentials") { return .reply(#"{"files":[]}"#) }
            if count == 2 { started.fulfill(); return .deferred(gate) }
            return request.httpMethod == "GET" ? .reply(#"["base"]"#) : .reply(#"{"status":"ok","config-version":8}"#)
        }
        model.setAuthImportClientForTesting(client)
        model.apiKeys = ["base"]
        let pending = Task { await model.refreshData(refreshQuotas: false) }
        await fulfillment(of: [started], timeout: 3)
        let added = await model.addAPIKey("new")
        XCTAssertTrue(added)
        gate.release(.reply(#"["base"]"#))
        let refreshed = await pending.value
        XCTAssertFalse(refreshed, "被新编辑取代的读取不能标记本轮完成")
        XCTAssertEqual(model.apiKeys, ["base", "new"])
        XCTAssertNil(model.errorMessage)
    }
}
