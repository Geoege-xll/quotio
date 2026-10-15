import XCTest
@testable import QuotioPlus

/// CPA 启动到菜单栏快照的离线回归。真实目录读取、CPA auth_index 请求、额度解析、
/// 槽位和通知均经过生产入口；仅将批量取数缩为 Claude，避免读取本机其他平台的凭据。
/// 另有用例直接运行生产批量入口并占住槽位，验证等待／取消契约，不启动真实代理进程。
@MainActor
final class ProxyStartupQuotaSyncTests: XCTestCase {
    private struct Fixture {
        let model: QuotaViewModel
        let settings: MenuBarSettingsManager
        let client: ManagementAPIClient
        let state: LifecycleHTTPState
        let file: AuthFile
        let session: UUID
    }

    private static let quotaResponse = #"{"status_code":200,"header":{},"body":"{\"five_hour\":{\"utilization\":45}}"}"#

    /// 所有 HTTP 由独立随机主机的 URLProtocol 截获，偏好使用临时 suite。
    /// 预置同一目录，避免目录变更写入用户偏好；只临时改变代理内存状态，并在结束后恢复。
    private func fixture(cadence: RefreshCadence = .manual, failing: Bool = false,
                         hold: Int? = nil, gate: LifecycleHTTPResponseGate? = nil,
                         started: XCTestExpectation? = nil) throws -> Fixture {
        let suite = "quotio-startup-quota-" + UUID().uuidString
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defaults.set(OperatingMode.localProxy.rawValue, forKey: "operatingMode")
        defaults.set(cadence.rawValue, forKey: "refreshCadence")
        let settings = MenuBarSettingsManager(defaults: defaults)
        settings.showQuotaInMenuBar = true
        let model = QuotaViewModel(
            directAuthService: DirectAuthFileService(authDirectory: FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)),
            startsBackgroundServices: false, modeManager: OperatingModeManager(defaults: defaults),
            menuBarSettings: settings, refreshSettings: RefreshSettingsManager(defaults: defaults),
            warmupSettings: WarmupSettingsManager(defaults: defaults),
            notificationManager: NotificationManager(testDefaults: defaults, notificationSink: { _ in }))
        model.customProvidersForTesting = []
        let name = "startup-fixture-" + UUID().uuidString + ".json"
        let directory = "{\"files\":[{\"id\":\"fixture\",\"name\":\"" + name
            + "\",\"provider\":\"claude\",\"email\":\"work@example.invalid\",\"status\":\"ready\",\"auth_index\":\"startup-auth\"}]}"
        let file = try XCTUnwrap(JSONDecoder().decode(AuthFilesResponse.self, from: Data(directory.utf8)).files.first)
        model.authFiles = [file]
        settings.toggleItem(MenuBarQuotaItem(provider: AIProvider.claude.rawValue, accountKey: file.quotaLookupKey))
        let host = UUID().uuidString.lowercased() + ".invalid"
        let quotaResponse = Self.quotaResponse
        let state = LifecycleHTTPState { request, count in
            if count == hold, let gate { started?.fulfill(); return .deferred(gate) }
            switch request.url?.path {
            case "/v8/management/credentials": return .reply(directory)
            case "/v8/management/config/access/api-keys": return .reply("[]")
            case "/v8/management/requests/api-call":
                return .reply(failing ? #"{"status_code":500,"header":{},"body":"upstream unavailable"}"# : quotaResponse)
            default: return .fail(.unsupportedURL)
            }
        }
        LifecycleHTTPProtocol.register(state, host: host)
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [LifecycleHTTPProtocol.self]
        let client = ManagementAPIClient(baseURL: "https://" + host + ManagementAPIClient.managementPath,
                                         authKey: "fixture", configuration: configuration)
        model.setAuthImportClientForTesting(client)
        let manager = model.proxyManager, oldStatus = manager.proxyStatus, oldSession = manager.runtimeSessionID
        let session = UUID()
        manager.setRuntimeStateForTesting(running: true, sessionID: session)
        // 模拟启动前已完成本地读取；此时后台轮询仍在节流期。
        model.recordQuotaRefreshStart()
        addTeardownBlock { @MainActor in
            manager.setRuntimeStateForTesting(running: oldStatus.running, sessionID: oldSession)
            await client.invalidate()
            LifecycleHTTPProtocol.remove(host: host)
            defaults.removePersistentDomain(forName: suite)
        }
        return Fixture(model: model, settings: settings, client: client, state: state, file: file, session: session)
    }

    private func refresh(_ f: Fixture) async throws {
        try await f.model.refreshProxyStartupDataForTesting(sessionID: f.session) {
            await f.model.refreshQuota(for: .claude, waitForAvailability: true)
        }
    }

    private func assertCancelled(_ task: Task<Void, Error>, file: StaticString = #filePath, line: UInt = #line) async {
        do { try await task.value; XCTFail("旧启动应以取消结束", file: file, line: line) }
        catch is CancellationError { }
        catch { XCTFail("意外错误：\(error)", file: file, line: line) }
    }

    /// 手动频率也应有一次启动初始化；不打开账号页、不点击刷新即可从未知变为 CPA 的 55%。
    /// 同时检查真实菜单栏通知及 auth_index，防止只更新页面或使用本地同邮箱缓存冒充结果。
    func testStartupPublishesQuotaAndMenuNotificationDespiteLocalThrottle() async throws {
        for cadence: RefreshCadence in [.manual, .tenMinutes] {
            let f = try fixture(cadence: cadence)
            XCTAssertFalse(f.model.isQuotaRefreshDueForPolling())
            XCTAssertEqual(f.model.menuBarQuotaItems.first?.percentage, -1)
            let published = expectation(description: "菜单栏收到 CPA 额度：" + cadence.rawValue)
            var received = false
            let observer = NotificationCenter.default.addObserver(forName: QuotaViewModel.quotaDataDidChangeNotification,
                                                                  object: nil, queue: .main) { _ in
                MainActor.assumeIsolated {
                    if !received, f.model.menuBarQuotaItems.first?.percentage == 55 {
                        received = true
                        published.fulfill()
                    }
                }
            }
            defer { NotificationCenter.default.removeObserver(observer) }
            try await refresh(f)
            await fulfillment(of: [published], timeout: 3)
            XCTAssertEqual(f.model.providerQuotas[.claude]?[f.file.quotaLookupKey]?.models.first?.percentage, 55)
            XCTAssertEqual(f.model.menuBarQuotaItems.first?.percentage, 55)
            XCTAssertEqual(f.settings.selectedItems.count, 1)
            XCTAssertTrue(f.model.refreshingProviders.isEmpty)
            // 两次启动目录／密钥读取，随后一次单提供商目录和 usage/profile；没有目录暗中派生的额外刷新。
            XCTAssertEqual(f.state.requests.filter { $0.url.path.hasSuffix("/credentials") }.count, 3)
            let calls = f.state.requests.filter { $0.url.path.hasSuffix("/api-call") }
            XCTAssertEqual(calls.count, 2)
            for call in calls {
                let request = try JSONDecoder().decode(APICallRequest.self, from: XCTUnwrap(call.body))
                XCTAssertEqual(request.authIndex, "startup-auth")
                XCTAssertEqual(request.header?["Authorization"], "Bearer $TOKEN$")
            }
        }
    }

    /// 直接经过生产首轮批量预约；旧刷新尚未结束时不能静默跳过，取消也不能释放旧拥有者的槽位。
    func testProductionStartupWaitsForBusyBatchAndCancellationPreservesOwner() async throws {
        let f = try fixture()
        XCTAssertTrue(f.model.beginBatchRefresh(providers: [.glm]))
        defer { f.model.endBatchRefresh(providers: [.glm]) }
        var finished = false
        let task = Task {
            defer { finished = true }
            try await f.model.refreshProxyStartupData(sessionID: f.session)
        }
        // 有界等待两次目录和密钥读取完成；随后只允许停在额度槽位，不能进入任何真实获取器。
        for _ in 0..<300 where f.state.requestCount < 4 { try await Task.sleep(for: .milliseconds(10)) }
        XCTAssertEqual(f.state.requestCount, 4)
        try await Task.sleep(for: .milliseconds(120))
        XCTAssertFalse(finished)
        XCTAssertEqual(f.model.refreshingProviders, [.glm])
        task.cancel()
        await assertCancelled(task)
        XCTAssertEqual(f.state.requestCount, 4)
        XCTAssertEqual(f.model.refreshingProviders, [.glm])
        XCTAssertNil(f.model.providerQuotas[.claude]?[f.file.quotaLookupKey])
    }

    /// 旧单提供商刷新持有槽位时，首轮真实 CPA 读取在其释放后继续，最终更新同一个菜单快照。
    func testStartupWaitsForScopedRefreshThenPublishesQuota() async throws {
        let f = try fixture()
        XCTAssertTrue(f.model.beginScopedRefresh(provider: .claude))
        let reachedQuota = expectation(description: "已进入启动首轮额度")
        let task = Task {
            try await f.model.refreshProxyStartupDataForTesting(sessionID: f.session) {
                reachedQuota.fulfill()
                await f.model.refreshQuota(for: .claude, waitForAvailability: true)
            }
        }
        await fulfillment(of: [reachedQuota], timeout: 3)
        XCTAssertEqual(f.state.requestCount, 4)
        XCTAssertEqual(f.model.menuBarQuotaItems.first?.percentage, -1)
        f.model.endScopedRefresh(provider: .claude)
        try await task.value
        XCTAssertEqual(f.model.menuBarQuotaItems.first?.percentage, 55)
        XCTAssertTrue(f.model.refreshingProviders.isEmpty)
    }

    /// 第一段目录返回时来源已失效，旧启动不能再读取密钥、进入首轮额度或继续后续预热流程。
    func testSourceChangesDuringDirectoryPreventStartupQuota() async throws {
        for change in ["cancel", "stop", "restart", "client", "mode"] {
            let gate = LifecycleHTTPResponseGate(), started = expectation(description: change)
            let f = try fixture(hold: 1, gate: gate, started: started)
            var calls = 0
            let task = Task {
                try await f.model.refreshProxyStartupDataForTesting(sessionID: f.session) { calls += 1 }
            }
            await fulfillment(of: [started], timeout: 3)
            switch change {
            case "cancel": task.cancel()
            case "stop": f.model.proxyManager.setRuntimeStateForTesting(running: false, sessionID: f.session)
            case "restart": f.model.proxyManager.setRuntimeStateForTesting(running: true, sessionID: UUID())
            case "client": f.model.setAuthImportClientForTesting(nil)
            default: f.model.modeManager.setMode(.monitor)
            }
            gate.release(.reply("{\"files\":[]}"))
            await assertCancelled(task)
            XCTAssertEqual(calls, 0, change)
            XCTAssertEqual(f.state.requestCount, 1, change)
            XCTAssertEqual(f.model.authFiles.map(\.quotaLookupKey), [f.file.quotaLookupKey], change)
        }
    }

    /// 已发出的 CPA 响应迟到时仍由原获取器检查运行会话；不会给重启后的新菜单写回旧额度。
    func testLateCPAQuotaCannotPublishIntoRestartedSession() async throws {
        let gate = LifecycleHTTPResponseGate(), started = expectation(description: "额度请求已挂起")
        let f = try fixture(hold: 6, gate: gate, started: started)
        let task = Task { try await refresh(f) }
        await fulfillment(of: [started], timeout: 3)
        f.model.proxyManager.setRuntimeStateForTesting(running: true, sessionID: UUID())
        gate.release(.reply(Self.quotaResponse))
        await assertCancelled(task)
        XCTAssertNil(f.model.providerQuotas[.claude]?[f.file.quotaLookupKey])
        XCTAssertEqual(f.model.menuBarQuotaItems.first?.percentage, -1)
        XCTAssertTrue(f.model.refreshingProviders.isEmpty)
    }

    /// CPA 主额度失败时显示未知和原失败状态；首轮初始化不能把本地其他账号额度当作成功结果。
    func testFailedStartupQuotaPreservesUnknownAndFailureState() async throws {
        let f = try fixture(failing: true)
        try await refresh(f)
        XCTAssertNil(f.model.providerQuotas[.claude]?[f.file.quotaLookupKey])
        XCTAssertEqual(f.model.menuBarQuotaItems.first?.percentage, -1)
        XCTAssertNotNil(f.model.monitorAccountIssues[QuotaAccountID(provider: .claude, accountKey: f.file.quotaLookupKey)])
        XCTAssertEqual(f.state.requests.filter { $0.url.path.hasSuffix("/api-call") }.count, 2)
        XCTAssertTrue(f.model.refreshingProviders.isEmpty)
    }
}
