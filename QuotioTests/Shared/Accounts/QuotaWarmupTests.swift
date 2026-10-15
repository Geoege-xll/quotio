import XCTest
@testable import QuotioPlus

/// 预热拆分的离线回归：临时偏好与 URLProtocol 隔离预热设置和请求，所有预热账号均为人工样本。
/// VM 沿用原基础设施构造且不启停 CPA；调度验证停服路径，执行仍经过原服务、缓存与请求编码。
@MainActor
final class QuotaWarmupTests: XCTestCase {
    private struct Fixture {
        let defaults: UserDefaults
        let settings: WarmupSettingsManager
        let model: QuotaViewModel
    }

    private func fixture() throws -> Fixture {
        let suite = "quotio-warmup-tests-" + UUID().uuidString
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defaults.set(OperatingMode.localProxy.rawValue, forKey: "operatingMode")
        let settings = WarmupSettingsManager(defaults: defaults)
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let model = QuotaViewModel(
            directAuthService: DirectAuthFileService(authDirectory: directory), startsBackgroundServices: false,
            modeManager: OperatingModeManager(defaults: defaults), menuBarSettings: MenuBarSettingsManager(defaults: defaults),
            refreshSettings: RefreshSettingsManager(defaults: defaults), warmupSettings: settings
        )
        addTeardownBlock { @MainActor in
            // 经原调度入口取消测试启动的等待任务，不引入新的生产取消入口或遗留后台循环。
            settings.enabledAccountIds = []
            model.restartWarmupScheduler()
            model.stopQuotaAutoRefresh()
            defaults.removePersistentDomain(forName: suite)
        }
        return Fixture(defaults: defaults, settings: settings, model: model)
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
        addTeardownBlock {
            await client.invalidate()
            LifecycleHTTPProtocol.remove(host: host)
        }
        return (client, state)
    }

    private func authFile(_ name: String, index: String, email: String = "same@example.com") throws -> AuthFile {
        let json: [String: Any] = ["name": name, "provider": "antigravity", "auth_index": index,
                                   "email": email, "status": "ready"]
        return try JSONDecoder().decode(AuthFile.self, from: JSONSerialization.data(withJSONObject: json))
    }

    private var models: [WarmupModelInfo] {
        [WarmupModelInfo(id: "alpha", ownedBy: "fixture", provider: "antigravity"),
         WarmupModelInfo(id: "beta", ownedBy: nil, provider: nil)]
    }

    func testInjectedPreferencesRestoreLegacyKeysAndAccountOverrides() throws {
        let f = try fixture(), id = "antigravity::work::suffix"
        f.defaults.set([id], forKey: "warmupEnabledAccounts")
        f.defaults.set("2h", forKey: "warmupCadence")
        f.defaults.set("daily", forKey: "warmupScheduleMode")
        f.defaults.set(2000, forKey: "warmupDailyMinutes")
        f.defaults.set(try JSONEncoder().encode([id: ["alpha", "beta"]]), forKey: "warmupSelectedModels")
        f.defaults.set(try JSONEncoder().encode([id: "30min"]), forKey: "warmupCadenceByAccount")
        f.defaults.set(try JSONEncoder().encode([id: "interval"]), forKey: "warmupScheduleModeByAccount")
        f.defaults.set(try JSONEncoder().encode([id: 75]), forKey: "warmupDailyMinutesByAccount")
        let restored = WarmupSettingsManager(defaults: f.defaults)
        XCTAssertTrue(restored.isEnabled(provider: .antigravity, accountKey: "work::suffix"))
        XCTAssertEqual(restored.warmupCadence, .twoHours)
        XCTAssertEqual(restored.warmupDailyMinutes, 1439)
        XCTAssertEqual(restored.warmupCadence(provider: .antigravity, accountKey: "work::suffix"), .thirtyMinutes)
        XCTAssertEqual(restored.warmupScheduleMode(provider: .antigravity, accountKey: "work::suffix"), .interval)
        XCTAssertEqual(restored.warmupDailyMinutes(provider: .antigravity, accountKey: "work::suffix"), 75)
        XCTAssertEqual(restored.selectedModels(provider: .antigravity, accountKey: "work::suffix"), ["alpha", "beta"])
    }

    func testEnableControlsKeepProviderRestrictionAndDoNotRepeatCallbacks() throws {
        let f = try fixture()
        var changes = 0
        f.settings.onEnabledAccountsChanged = { _ in changes += 1 }
        f.model.setWarmupEnabled(true, provider: .antigravity, accountKey: "work")
        f.model.setWarmupEnabled(true, provider: .antigravity, accountKey: "work")
        f.model.setWarmupEnabled(true, provider: .claude, accountKey: "other")
        f.model.toggleWarmup(for: .claude, accountKey: "other")
        XCTAssertEqual(changes, 1)
        XCTAssertTrue(f.model.isWarmupEnabled(for: .antigravity, accountKey: "work"))
        XCTAssertFalse(f.model.isWarmupEnabled(for: .claude, accountKey: "other"))
        f.model.toggleWarmup(for: .antigravity, accountKey: "work")
        XCTAssertEqual(changes, 2)
        XCTAssertTrue(f.settings.enabledAccountIds.isEmpty)
    }

    func testDailyTimeUsesTodayOnlyWhenStrictlyLater() throws {
        let f = try fixture(), calendar = Calendar.current
        let due = try XCTUnwrap(calendar.date(from: DateComponents(year: 2026, month: 10, day: 15, hour: 9)))
        let before = try XCTUnwrap(calendar.date(byAdding: .second, value: -1, to: due))
        let after = try XCTUnwrap(calendar.date(byAdding: .second, value: 1, to: due))
        let tomorrow = try XCTUnwrap(calendar.date(byAdding: .day, value: 1, to: due))
        XCTAssertEqual(f.model.nextDailyRunDate(minutes: 540, now: before), due)
        XCTAssertEqual(f.model.nextDailyRunDate(minutes: 540, now: due), tomorrow)
        XCTAssertEqual(f.model.nextDailyRunDate(minutes: 540, now: after), tomorrow)
    }

    func testTargetsKeepOriginalParsingFilteringAndStableOrder() throws {
        let f = try fixture()
        f.settings.enabledAccountIds = ["antigravity::z", "antigravity::a::suffix", "claude::x", "invalid", "antigravity::"]
        XCTAssertEqual(f.model.warmupTargets().map(\.accountKey), ["a::suffix", "z"])
        XCTAssertTrue(f.model.warmupTargets().allSatisfy { $0.provider == .antigravity })
    }

    func testStoppedCycleReschedulesWithoutErasingLastFailure() async throws {
        let f = try fixture()
        guard !f.model.proxyManager.proxyStatus.running else { return XCTFail("停服夹具不得连接运行中的 CPA") }
        f.settings.setEnabled(true, provider: .antigravity, accountKey: "interval")
        f.settings.setEnabled(true, provider: .antigravity, accountKey: "daily")
        f.settings.setWarmupCadence(.fifteenMinutes, provider: .antigravity, accountKey: "interval")
        f.settings.setWarmupScheduleMode(.daily, provider: .antigravity, accountKey: "daily")
        f.settings.setWarmupDailyMinutes(0, provider: .antigravity, accountKey: "daily")
        let key = WarmupAccountKey(provider: .antigravity, accountKey: "interval")
        f.model.updateWarmupStatus(for: key) { $0.lastError = "previous failure" }
        let before = Date()
        await f.model.runWarmupCycle()
        let after = Date()
        let next = try XCTUnwrap(f.model.warmupNextRunDate(provider: .antigravity, accountKey: "interval"))
        XCTAssertGreaterThanOrEqual(next, before.addingTimeInterval(900))
        XCTAssertLessThanOrEqual(next, after.addingTimeInterval(900))
        XCTAssertEqual(f.model.warmupNextRunDate(provider: .antigravity, accountKey: "daily"),
                       f.model.nextDailyRunDate(minutes: 0, now: before))
        XCTAssertEqual(f.model.warmupStatus(provider: .antigravity, accountKey: "interval").lastError, "previous failure")
        XCTAssertEqual(f.model.warmupStatus(provider: .antigravity, accountKey: "interval").nextRun, next)
    }

    func testSchedulerRestartKeepsImmediateIntervalAndDailyPlan() throws {
        let f = try fixture()
        guard !f.model.proxyManager.proxyStatus.running else { return XCTFail("调度夹具不得连接运行中的 CPA") }
        f.settings.setEnabled(true, provider: .antigravity, accountKey: "interval")
        f.settings.setEnabled(true, provider: .antigravity, accountKey: "daily")
        f.settings.setWarmupScheduleMode(.daily, provider: .antigravity, accountKey: "daily")
        f.settings.setWarmupDailyMinutes(0, provider: .antigravity, accountKey: "daily")
        let before = Date()
        f.model.restartWarmupScheduler()
        let after = Date()
        let next = try XCTUnwrap(f.model.warmupNextRunDate(provider: .antigravity, accountKey: "interval"))
        XCTAssertGreaterThanOrEqual(next, before)
        XCTAssertLessThanOrEqual(next, after)
        XCTAssertEqual(f.model.warmupNextRunDate(provider: .antigravity, accountKey: "daily"),
                       f.model.nextDailyRunDate(minutes: 0, now: before))
        XCTAssertEqual(f.model.warmupStatus(provider: .antigravity, accountKey: "interval").nextRun, next)
        // 清空设置后再调用原入口，立即取消刚建立的等待 Task；清理过程同样只作用于临时设置。
        f.settings.enabledAccountIds = []
        f.model.restartWarmupScheduler()
    }

    func testAuthLookupRequiresExactCredentialIdentityAndValidRoutingFields() throws {
        let f = try fixture(), a = try authFile(" a.json ", index: "index-a"), b = try authFile("b.json", index: "index-b")
        f.model.authFiles = [a, b]
        XCTAssertEqual(f.model.warmupAuthInfo(provider: .antigravity, accountKey: a.quotaLookupKey)?.authIndex, "index-a")
        XCTAssertEqual(f.model.warmupAuthInfo(provider: .antigravity, accountKey: a.quotaLookupKey)?.authFileName, "a.json")
        XCTAssertEqual(f.model.warmupAuthInfo(provider: .antigravity, accountKey: b.quotaLookupKey)?.authIndex, "index-b")
        XCTAssertNil(f.model.warmupAuthInfo(provider: .antigravity, accountKey: "same@example.com"))
        XCTAssertNil(f.model.warmupAuthInfo(provider: .claude, accountKey: a.quotaLookupKey))
        let invalid = try authFile("missing-index.json", index: "")
        f.model.authFiles = [invalid]
        XCTAssertNil(f.model.warmupAuthInfo(provider: .antigravity, accountKey: invalid.quotaLookupKey))
    }

    func testModelCacheReusesFreshEntriesSeparatesAccountsAndExpires() async throws {
        let f = try fixture()
        let (client, state) = self.client { _, count in
            .reply("{\"models\":[{\"id\":\"model-\(count)\",\"owned_by\":\"fixture-owner\",\"type\":\"antigravity\"}]}")
        }
        let first = await f.model.fetchWarmupModels(provider: .antigravity, accountKey: "a", authFileName: "a.json", apiClient: client)
        let reused = await f.model.fetchWarmupModels(provider: .antigravity, accountKey: "a", authFileName: "a.json", apiClient: client)
        XCTAssertEqual(first.map(\.id), ["model-1"])
        XCTAssertEqual(first.first?.ownedBy, "fixture-owner")
        XCTAssertEqual(first.first?.provider, "antigravity")
        XCTAssertEqual(reused.map(\.id), ["model-1"])
        XCTAssertEqual(state.requestCount, 1)
        let other = await f.model.fetchWarmupModels(provider: .antigravity, accountKey: "b", authFileName: "b.json", apiClient: client)
        XCTAssertEqual(other.map(\.id), ["model-2"])
        // 使用 Debug 数据入口放入八小时以前的样本，仍经过未改动的生产 TTL 分支重新请求。
        f.model.setWarmupModelCacheForTesting(provider: .antigravity, accountKey: "a", models: first,
                                             fetchedAt: Date().addingTimeInterval(-28_801))
        let expired = await f.model.fetchWarmupModels(provider: .antigravity, accountKey: "a", authFileName: "a.json", apiClient: client)
        XCTAssertEqual(expired.map(\.id), ["model-3"])
        XCTAssertEqual(state.requestCount, 3)
        XCTAssertTrue(state.requests.allSatisfy { $0.url.path.hasSuffix("/credentials/models") })
    }

    func testFailedAndCancelledModelReadsDoNotPopulateCache() async throws {
        let f = try fixture()
        let (client, state) = self.client { _, count in
            count == 1 ? .replyStatus("{}", 401) : .reply(#"{"models":[{"id":"recovered"}]}"#)
        }
        let failed = await f.model.fetchWarmupModels(provider: .antigravity, accountKey: "a", authFileName: "a.json", apiClient: client)
        XCTAssertTrue(failed.isEmpty)
        let recovered = await f.model.fetchWarmupModels(provider: .antigravity, accountKey: "a", authFileName: "a.json", apiClient: client)
        XCTAssertEqual(recovered.map(\.id), ["recovered"])
        XCTAssertEqual(state.requestCount, 2)
        await client.invalidate()
        let cancelled = await f.model.fetchWarmupModels(provider: .antigravity, accountKey: "b", authFileName: "b.json", apiClient: client)
        XCTAssertTrue(cancelled.isEmpty)
        let (fresh, _) = self.client { _, _ in .reply(#"{"models":[{"id":"fresh-session"}]}"#) }
        let newSession = await f.model.fetchWarmupModels(provider: .antigravity, accountKey: "b", authFileName: "b.json", apiClient: fresh)
        XCTAssertEqual(newSession.map(\.id), ["fresh-session"])
    }

    func testExecutionFiltersModelsAndKeepsFailureWhileContinuingSerially() async throws {
        let f = try fixture()
        f.settings.setSelectedModels(["missing", "alpha", "beta"], provider: .antigravity, accountKey: "a")
        let (client, state) = self.client { _, count in
            .reply(count <= 3 ? #"{"status_code":500,"body":"fixture failure"}"# : #"{"status_code":200}"#)
        }
        await f.model.warmupAccount(provider: .antigravity, accountKey: "a", availableModels: models,
                                    authIndex: "index-a", apiClient: client)
        let status = f.model.warmupStatus(provider: .antigravity, accountKey: "a")
        XCTAssertFalse(status.isRunning)
        XCTAssertNil(status.currentModel)
        XCTAssertNotNil(status.lastRun)
        XCTAssertEqual(status.progressTotal, 2)
        XCTAssertEqual(status.progressCompleted, 2)
        XCTAssertEqual(status.modelStates["alpha"], .failed)
        XCTAssertEqual(status.modelStates["beta"], .succeeded)
        XCTAssertNil(status.modelStates["missing"])
        XCTAssertEqual(status.lastError, "Warmup HTTP 500: fixture failure")
        let sentModels = try state.requests.map { record -> String in
            let request = try JSONDecoder().decode(APICallRequest.self, from: XCTUnwrap(record.body))
            XCTAssertEqual(request.authIndex, "index-a")
            XCTAssertEqual(request.method, "POST")
            let payload = try JSONDecoder().decode(AntigravityWarmupRequest.self,
                from: XCTUnwrap(request.data?.data(using: .utf8)))
            return payload.model
        }
        XCTAssertEqual(sentModels, ["alpha", "alpha", "alpha", "beta"])
    }

    func testExecutionCancellationStopsRemainingModelsAndFinishesPresentation() async throws {
        let f = try fixture()
        f.settings.setSelectedModels(["alpha", "beta"], provider: .antigravity, accountKey: "a")
        let started = expectation(description: "预热请求挂起")
        let (client, state) = self.client { _, _ in started.fulfill(); return .hold }
        let pending = Task {
            await f.model.warmupAccount(provider: .antigravity, accountKey: "a", availableModels: models,
                                        authIndex: "index-a", apiClient: client)
        }
        await fulfillment(of: [started], timeout: 3)
        XCTAssertTrue(f.model.warmupStatus(provider: .antigravity, accountKey: "a").isRunning)
        pending.cancel()
        await pending.value
        let status = f.model.warmupStatus(provider: .antigravity, accountKey: "a")
        XCTAssertFalse(status.isRunning)
        XCTAssertNil(status.currentModel)
        XCTAssertNotNil(status.lastRun)
        XCTAssertEqual(status.progressCompleted, 1)
        XCTAssertEqual(status.modelStates["alpha"], .failed)
        XCTAssertEqual(status.modelStates["beta"], .pending)
        XCTAssertEqual(state.requestCount, 1)
    }

    func testNoMatchingModelsDoesNotErasePreviousFailureOrStartRequest() async throws {
        let f = try fixture()
        f.settings.setSelectedModels(["missing"], provider: .antigravity, accountKey: "a")
        f.model.updateWarmupStatus(for: WarmupAccountKey(provider: .antigravity, accountKey: "a")) {
            $0.lastError = "previous failure"
        }
        let (client, state) = self.client { _, _ in XCTFail("无交集不能发起请求"); return .reply("{}") }
        await f.model.warmupAccount(provider: .antigravity, accountKey: "a", availableModels: models,
                                    authIndex: "index-a", apiClient: client)
        let status = f.model.warmupStatus(provider: .antigravity, accountKey: "a")
        XCTAssertEqual(status.lastError, "previous failure")
        XCTAssertNil(status.lastRun)
        XCTAssertFalse(status.isRunning)
        XCTAssertEqual(state.requestCount, 0)
    }
}
