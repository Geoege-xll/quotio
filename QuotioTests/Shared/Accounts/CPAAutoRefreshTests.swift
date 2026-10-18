import XCTest
@testable import QuotioPlus

/// CPA 自动轮询的离线回归：运行真实 refreshTask、管理请求、精确凭据取数及菜单投影。
/// 单调时钟由测试推进，外部额度批次缩为 Claude；不等待真实分钟、不启停用户 CPA、不开真实凭据目录。
@MainActor
final class CPAAutoRefreshTests: XCTestCase {
    private struct Fixture {
        let model: QuotaViewModel
        let clock: CPAPollingTestClock
        let response: CPAPollingResponses
        let state: LifecycleHTTPState
        let client: ManagementAPIClient
        let file: AuthFile
    }

    private func fixture(cadence: RefreshCadence = .tenMinutes, keyStatus: Int = 200,
                         credentialGate: LifecycleHTTPResponseGate? = nil,
                         credentialStarted: XCTestExpectation? = nil,
                         keyGate: LifecycleHTTPResponseGate? = nil,
                         keyStarted: XCTestExpectation? = nil) throws -> Fixture {
        let suite = "quotio-cpa-polling-" + UUID().uuidString
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
        let name = "polling-" + UUID().uuidString + ".json"
        let directory = "{\"files\":[{\"name\":\"" + name
            + "\",\"provider\":\"claude\",\"email\":\"fixture@example.invalid\",\"status\":\"ready\",\"auth_index\":\"polling-auth\"}]}"
        let file = try XCTUnwrap(JSONDecoder().decode(AuthFilesResponse.self, from: Data(directory.utf8)).files.first)
        model.authFiles = [file]
        settings.toggleItem(MenuBarQuotaItem(provider: AIProvider.claude.rawValue, accountKey: file.quotaLookupKey))
        let response = CPAPollingResponses()
        let state = LifecycleHTTPState { request, count in
            switch request.url?.path {
            case "/v8/management/credentials":
                if let credentialGate, count == 1 { credentialStarted?.fulfill(); return .deferred(credentialGate) }
                return .reply(directory)
            case "/v8/management/config/access/api-keys":
                if request.httpMethod != "GET" { return .reply(#"{"status":"ok","config-version":8}"#) }
                if let keyGate { keyStarted?.fulfill(); return .deferred(keyGate) }
                return .replyStatus("[]", keyStatus)
            case "/v8/management/requests/api-call":
                return .reply(response.quotaResponse())
            default: return .fail(.unsupportedURL)
            }
        }
        let host = UUID().uuidString.lowercased() + ".invalid"
        LifecycleHTTPProtocol.register(state, host: host)
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [LifecycleHTTPProtocol.self]
        let client = ManagementAPIClient(baseURL: "https://" + host + ManagementAPIClient.managementPath,
                                         authKey: "fixture", configuration: configuration)
        model.setAuthImportClientForTesting(client)
        let manager = model.proxyManager, oldStatus = manager.proxyStatus, oldSession = manager.runtimeSessionID
        manager.setRuntimeStateForTesting(running: true, sessionID: UUID())
        // 模拟首轮／手动批量刚记录过时间：机会性读取尚未到期，不应阻挡配置时钟已经到期的一轮。
        model.recordQuotaRefreshStart()
        addTeardownBlock { @MainActor in
            model.stopQuotaAutoRefresh()
            manager.setRuntimeStateForTesting(running: oldStatus.running, sessionID: oldSession)
            await client.invalidate()
            LifecycleHTTPProtocol.remove(host: host)
            defaults.removePersistentDomain(forName: suite)
        }
        return Fixture(model: model, clock: CPAPollingTestClock(), response: response,
                       state: state, client: client, file: file)
    }

    private func start(_ f: Fixture, refresh: (@MainActor () async -> Void)? = nil) {
        f.model.startCPAAutoRefreshForTesting(now: { f.clock.instant }, sleepUntil: { try await f.clock.sleep(until: $0) },
            refreshQuotas: refresh ?? { await f.model.refreshQuota(for: .claude, waitForAvailability: true) })
    }

    private func waitForSleep(_ count: Int, _ f: Fixture) async {
        if f.clock.deadlines.count >= count { return }
        let ready = expectation(description: "轮询已进入第 \(count) 次等待")
        f.clock.onSleep = { if $0 == count { ready.fulfill() } }
        await fulfillment(of: [ready], timeout: 3)
        f.clock.onSleep = nil
    }

    private func assertQuota(_ value: Double, _ f: Fixture, file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertEqual(f.model.providerQuotas[.claude]?[f.file.quotaLookupKey]?.models.first?.percentage, value, file: file, line: line)
        XCTAssertEqual(f.model.menuBarQuotaItems.first?.percentage, value, file: file, line: line)
        XCTAssertTrue(f.model.refreshingProviders.isEmpty, file: file, line: line)
    }

    func testEveryConfiguredCadenceRefreshesOnFirstTickDespiteRecentBatch() async throws {
        for cadence: RefreshCadence in [.oneMinute, .twoMinutes, .fiveMinutes, .tenMinutes, .fifteenMinutes] {
            let f = try fixture(cadence: cadence)
            XCTAssertFalse(f.model.isQuotaRefreshDueForPolling())
            let initial = f.clock.instant
            start(f)
            await waitForSleep(1, f)
            let interval = Duration.seconds(try XCTUnwrap(cadence.intervalSeconds))
            XCTAssertEqual(f.clock.deadlines.first, initial.advanced(by: interval))
            f.clock.advance(by: interval)
            await waitForSleep(2, f)
            assertQuota(55, f)
            let calls = f.state.requests.filter { $0.url.path.hasSuffix("/api-call") }
            XCTAssertEqual(calls.count, 2, "首个到期周期必须实际读取额度，不应再等第二轮")
            for call in calls {
                let request = try JSONDecoder().decode(APICallRequest.self, from: XCTUnwrap(call.body))
                XCTAssertEqual(request.authIndex, "polling-auth")
                XCTAssertEqual(request.header?["Authorization"], "Bearer $TOKEN$")
            }
            f.model.stopQuotaAutoRefresh()
        }
    }

    func testConsecutiveTicksUpdateAccountSnapshotAndMenuNotification() async throws {
        let f = try fixture()
        let published = expectation(description: "菜单收到第二轮新额度")
        var notified = false
        let observer = NotificationCenter.default.addObserver(forName: QuotaViewModel.quotaDataDidChangeNotification,
                                                              object: nil, queue: .main) { _ in
            MainActor.assumeIsolated {
                if !notified, f.model.menuBarQuotaItems.first?.percentage == 30 {
                    notified = true
                    published.fulfill()
                }
            }
        }
        defer { NotificationCenter.default.removeObserver(observer) }
        start(f)
        await waitForSleep(1, f)
        f.clock.advance(by: .seconds(600))
        await waitForSleep(2, f)
        assertQuota(55, f)
        let firstUpdated = try XCTUnwrap(f.model.providerQuotas[.claude]?[f.file.quotaLookupKey]?.lastUpdated)
        f.response.setUsed(70)
        f.clock.advance(by: .seconds(600))
        await waitForSleep(3, f)
        await fulfillment(of: [published], timeout: 3)
        assertQuota(30, f)
        XCTAssertGreaterThanOrEqual(try XCTUnwrap(f.model.providerQuotas[.claude]?[f.file.quotaLookupKey]?.lastUpdated), firstUpdated)
    }

    func testAPIKeyReadFailureDoesNotSuppressAccountQuota() async throws {
        let f = try fixture(keyStatus: 503)
        start(f)
        await waitForSleep(1, f)
        f.clock.advance(by: .seconds(600))
        await waitForSleep(2, f)
        assertQuota(55, f)
        XCTAssertNotNil(f.model.errorMessage, "保留独立的密钥读取错误，不能把它当作整轮目录成功")
    }

    func testPendingAPIKeyMutationDoesNotSuppressQuotaOrLoseMutationOwnership() async throws {
        let gate = LifecycleHTTPResponseGate(), editing = expectation(description: "密钥编辑已挂起")
        let f = try fixture(keyGate: gate, keyStarted: editing)
        f.model.apiKeys = ["existing"]
        let mutation = Task { await f.model.addAPIKey("new") }
        await fulfillment(of: [editing], timeout: 3)
        XCTAssertTrue(f.model.isMutatingAPIKeys)
        start(f)
        await waitForSleep(1, f)
        f.clock.advance(by: .seconds(600))
        await waitForSleep(2, f)
        assertQuota(55, f)
        XCTAssertTrue(f.model.isMutatingAPIKeys)
        XCTAssertEqual(f.state.requests.filter { $0.url.path.hasSuffix("/api-keys") }.count, 1)
        gate.release(.reply(#"["existing"]"#))
        let mutated = await mutation.value
        XCTAssertTrue(mutated)
        XCTAssertEqual(f.model.apiKeys, ["existing", "new"])
        XCTAssertFalse(f.model.isMutatingAPIKeys)
    }

    func testLateInitialLocalRefreshCannotReplaceRunningCPATimer() async throws {
        let f = try fixture(), gate = CPAPollingInitializationGate()
        let initialStarted = expectation(description: "启动本地读取仍未完成")
        f.model.proxyManager.setRuntimeStateForTesting(running: false, sessionID: UUID())
        let initialization = Task {
            await f.model.initializeFullModeForTesting(refreshQuotas: {
                initialStarted.fulfill()
                await gate.wait()
            }, shouldAutoStartProxy: { false })
        }
        await fulfillment(of: [initialStarted], timeout: 3)
        // 只模拟用户已启动代理的内存来源；不调用 startProxy，也不触碰用户正在运行的服务。
        f.model.proxyManager.setRuntimeStateForTesting(running: true, sessionID: UUID())
        start(f)
        await waitForSleep(1, f)
        gate.release()
        await initialization.value
        XCTAssertEqual(f.clock.cancelledWaits, 0, "迟到初始化不得取消已建立的 CPA 轮询")
        f.clock.advance(by: .seconds(600))
        await waitForSleep(2, f)
        assertQuota(55, f)
    }

    func testCancellationDuringSleepDoesNotReadOrStartAnotherCycle() async throws {
        let f = try fixture()
        start(f)
        await waitForSleep(1, f)
        let cancelled = expectation(description: "原时钟等待被取消")
        f.clock.onCancel = { cancelled.fulfill() }
        f.model.stopQuotaAutoRefresh()
        await fulfillment(of: [cancelled], timeout: 3)
        f.clock.advance(by: .seconds(1200))
        XCTAssertEqual(f.state.requestCount, 0)
        XCTAssertFalse(f.model.isQuotaAutoRefreshScheduledForTesting)
    }

    func testOldCycleRejectsLateDirectoryAndNextSessionContinuesPolling() async throws {
        for change in ["mode", "session", "client", "stopped"] {
            let gate = LifecycleHTTPResponseGate(), started = expectation(description: change + " 旧目录已挂起")
            let f = try fixture(credentialGate: gate, credentialStarted: started)
            start(f)
            await waitForSleep(1, f)
            f.clock.advance(by: .seconds(600))
            await fulfillment(of: [started], timeout: 3)
            f.model.providerQuotas[.claude] = [f.file.quotaLookupKey: ProviderQuotaData(models: [ModelQuota(name: "new", percentage: 77, resetTime: "")])]
            switch change {
            case "mode": f.model.modeManager.setMode(.monitor)
            case "session": f.model.proxyManager.setRuntimeStateForTesting(running: true, sessionID: UUID())
            case "client":
                // 显式换成同一离线主机的另一客户端，验证下一轮能采样新身份，而非永久停掉轮询。
                let configuration = URLSessionConfiguration.ephemeral
                configuration.protocolClasses = [LifecycleHTTPProtocol.self]
                let host = try XCTUnwrap(f.state.requests.first?.url.host)
                let replacement = ManagementAPIClient(baseURL: "https://" + host + ManagementAPIClient.managementPath,
                                                      authKey: "fixture", configuration: configuration)
                f.model.setAuthImportClientForTesting(replacement)
                addTeardownBlock { await replacement.invalidate() }
            default: f.model.proxyManager.setRuntimeStateForTesting(running: false, sessionID: UUID())
            }
            gate.release(.reply(#"{"files":[]}"#))
            if change == "mode" { await f.model.waitForQuotaAutoRefreshForTesting() }
            else { await waitForSleep(2, f) }
            assertQuota(77, f)
            XCTAssertEqual(f.state.requests.filter { $0.url.path.hasSuffix("/api-call") }.count, 0)
            if change == "mode" {
                XCTAssertEqual(f.clock.deadlines.count, 1)
            } else {
                // 管理器内部重启不会调用 VM.startProxy；旧轮必须失效，但唯一调度不能因此退出。
                if change == "stopped" {
                    let count = f.state.requestCount
                    f.clock.advance(by: .seconds(600))
                    await waitForSleep(3, f)
                    XCTAssertEqual(f.state.requestCount, count, "停服期间跳过取数，保留下一到期点")
                    f.model.proxyManager.setRuntimeStateForTesting(running: true, sessionID: UUID())
                }
                f.response.setUsed(70)
                let nextWait = f.clock.deadlines.count + 1
                f.clock.advance(by: .seconds(600))
                await waitForSleep(nextWait, f)
                assertQuota(30, f)
            }
            f.model.stopQuotaAutoRefresh()
        }
    }

    func testDueBatchWaitsForExistingSlotAndCancellationDoesNotReleaseItsOwner() async throws {
        let f = try fixture()
        XCTAssertTrue(f.model.beginBatchRefresh(providers: [.glm]))
        defer { f.model.endBatchRefresh(providers: [.glm]) }
        let entered = expectation(description: "到期批次开始等待槽位")
        let ended = expectation(description: "取消后批次已退出")
        start(f) {
            entered.fulfill()
            await f.model.refreshAllQuotas(waitForAvailability: true)
            ended.fulfill()
        }
        await waitForSleep(1, f)
        f.clock.advance(by: .seconds(600))
        await fulfillment(of: [entered], timeout: 3)
        XCTAssertEqual(f.model.refreshingProviders, [.glm])
        f.model.stopQuotaAutoRefresh()
        await fulfillment(of: [ended], timeout: 3)
        XCTAssertEqual(f.model.refreshingProviders, [.glm])
        XCTAssertEqual(f.state.requests.filter { $0.url.path.hasSuffix("/api-call") }.count, 0)
    }

    func testNetworkDurationKeepsCadenceBoundaryAndOverrunDoesNotBurst() async throws {
        for duration in [20, 1500] {
            let f = try fixture(), origin = f.clock.instant
            start(f) {
                f.clock.advance(by: .seconds(duration))
                await f.model.refreshQuota(for: .claude, waitForAvailability: true)
            }
            await waitForSleep(1, f)
            f.clock.advance(by: .seconds(600))
            await waitForSleep(2, f)
            let expected = duration == 20 ? origin.advanced(by: .seconds(1200)) : f.clock.instant.advanced(by: .seconds(600))
            XCTAssertEqual(f.clock.deadlines[1], expected)
            XCTAssertEqual(f.state.requests.filter { $0.url.path.hasSuffix("/api-call") }.count, 2)
            assertQuota(55, f)
            f.model.stopQuotaAutoRefresh()
        }
    }

    func testManualCadenceStopsPollingAndNewCadenceOwnsOnlyOneTimer() async throws {
        let f = try fixture()
        start(f)
        await waitForSleep(1, f)
        let cancelled = expectation(description: "切换手动取消旧计时")
        f.clock.onCancel = { cancelled.fulfill() }
        f.model.refreshSettings.refreshCadence = .manual
        f.model.restartAutoRefresh()
        await fulfillment(of: [cancelled], timeout: 3)
        XCTAssertFalse(f.model.isQuotaAutoRefreshScheduledForTesting)
        XCTAssertEqual(f.state.requestCount, 0)
        f.clock.onCancel = nil
        f.model.refreshSettings.refreshCadence = .oneMinute
        start(f)
        await waitForSleep(2, f)
        XCTAssertEqual(f.clock.deadlines[1], f.clock.instant.advanced(by: .seconds(60)))
        f.clock.advance(by: .seconds(60))
        await waitForSleep(3, f)
        assertQuota(55, f)
    }
}

/// 仅测试时推进单调时间；每次 sleep 有独立身份，取消旧等待不会误清新周期。
@MainActor
private final class CPAPollingTestClock {
    private(set) var instant = ContinuousClock.now
    private(set) var deadlines: [ContinuousClock.Instant] = []
    private(set) var cancelledWaits = 0
    var onSleep: ((Int) -> Void)?
    var onCancel: (() -> Void)?
    private var waits: [UUID: (ContinuousClock.Instant, CheckedContinuation<Void, Error>)] = [:]

    func sleep(until deadline: ContinuousClock.Instant) async throws {
        let id = UUID()
        try await withTaskCancellationHandler {
            try Task.checkCancellation()
            try await withCheckedThrowingContinuation { continuation in
                deadlines.append(deadline)
                if deadline <= instant { continuation.resume() }
                else { waits[id] = (deadline, continuation) }
                onSleep?(deadlines.count)
            }
        } onCancel: {
            Task { @MainActor in
                if let wait = self.waits.removeValue(forKey: id) {
                    self.cancelledWaits += 1
                    wait.1.resume(throwing: CancellationError())
                    self.onCancel?()
                }
            }
        }
    }

    func advance(by duration: Duration) {
        instant = instant.advanced(by: duration)
        for id in Array(waits.keys) {
            if let wait = waits[id], wait.0 <= instant {
                waits.removeValue(forKey: id)
                wait.1.resume()
            }
        }
    }
}

/// 网络回调由 URLProtocol 在线程间调用，只在锁内交换构造读数，不共享真实账号数据。
private final class CPAPollingResponses: @unchecked Sendable {
    private let lock = NSLock()
    private var used = 45
    func setUsed(_ value: Int) { lock.withLock { used = value } }
    func quotaResponse() -> String {
        let value = lock.withLock { used }
        let body = "{\"five_hour\":{\"utilization\":\(value)}}"
        let data = try! JSONSerialization.data(withJSONObject: ["status_code": 200, "header": [:], "body": body])
        return String(decoding: data, as: UTF8.self)
    }
}

@MainActor
private final class CPAPollingInitializationGate {
    private var continuation: CheckedContinuation<Void, Never>?
    func wait() async { await withCheckedContinuation { continuation = $0 } }
    func release() { continuation?.resume(); continuation = nil }
}
