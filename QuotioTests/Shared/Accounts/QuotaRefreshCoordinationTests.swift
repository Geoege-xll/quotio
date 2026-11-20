import XCTest
@testable import QuotioPlus

/// 验证迁移后的真实批量入口与主类槽位／节流边界，不替换刷新流程本身。
/// 每个夹具使用独立偏好和空目录并关闭后台服务；预先占用冲突槽位，确保不会读取用户凭据或发起网络请求。
@MainActor
final class QuotaRefreshCoordinationTests: XCTestCase {
    private func viewModel() throws -> QuotaViewModel {
        let suite = "quotio-refresh-coordination-tests-" + UUID().uuidString
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defaults.set(OperatingMode.localProxy.rawValue, forKey: "operatingMode")
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let model = QuotaViewModel(
            directAuthService: DirectAuthFileService(authDirectory: directory),
            startsBackgroundServices: false,
            modeManager: OperatingModeManager(defaults: defaults),
            menuBarSettings: MenuBarSettingsManager(defaults: defaults),
            refreshSettings: RefreshSettingsManager(defaults: defaults)
        )
        let proxy = model.proxyManager, initialRunning = proxy.proxyStatus.running, initialSession = proxy.runtimeSessionID
        proxy.setRuntimeStateForTesting(running: true, sessionID: UUID())
        let host = UUID().uuidString.lowercased() + ".invalid"
        let requests = LifecycleHTTPState { _, _ in .fail(.unsupportedURL) }
        LifecycleHTTPProtocol.register(requests, host: host)
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [LifecycleHTTPProtocol.self]
        let client = ManagementAPIClient(baseURL: "https://" + host + ManagementAPIClient.managementPath,
                                         authKey: "fixture", configuration: configuration)
        model.setAuthImportClientForTesting(client)
        addTeardownBlock { @MainActor in
            model.stopQuotaAutoRefresh()
            proxy.setRuntimeStateForTesting(running: initialRunning, sessionID: initialSession)
            await client.invalidate()
            LifecycleHTTPProtocol.remove(host: host)
            XCTAssertEqual(requests.requestCount, 0, "没有取得槽位时，既不读 CPA 目录，也不发起额度请求")
            defaults.removePersistentDomain(forName: suite)
        }
        return model
    }

    /// 两个原批量入口都必须经过真实槽位申请，不能只测试独立的预约辅助或模拟布尔值。
    private func refreshBatch(_ model: QuotaViewModel, unified: Bool, wait: Bool) async {
        if unified {
            await model.refreshQuotasUnified(waitForAvailability: wait)
        } else {
            await model.refreshAllQuotas(waitForAvailability: wait)
        }
    }

    /// 后台批次遇到已有 GLM 刷新时直接合并退出；不能提前消耗节流时间，也不能释放其他刷新持有的槽位。
    func testBlockedBackgroundBatchesPreserveThrottleAndExistingSlot() async throws {
        for unified in [false, true] {
            let model = try viewModel()
            let previousTime = Date(timeIntervalSince1970: 100)
            model.lastQuotaRefreshTime = previousTime
            XCTAssertTrue(model.beginBatchRefresh(providers: [.glm]))
            defer { model.endBatchRefresh(providers: [.glm]) }

            await refreshBatch(model, unified: unified, wait: false)

            XCTAssertTrue(model.isQuotaRefreshDueForPolling(), "未取得槽位不能记录一次额度批次开始")
            XCTAssertEqual(model.lastQuotaRefreshTime, previousTime)
            XCTAssertEqual(model.refreshingProviders, [.glm])
            XCTAssertTrue(model.refreshingAccounts.isEmpty)
            XCTAssertTrue(model.isRefreshBlocked(for: QuotaAccountID(provider: .glm, accountKey: "fixture")))
        }
    }

    /// 手动批次在冲突槽位上等待期间取消，两个入口都应退出且保留原占用者，避免取消触发错误的 defer 释放。
    func testCancelledWaitingBatchesPreserveThrottleAndExistingSlot() async throws {
        for unified in [false, true] {
            let model = try viewModel()
            let previousTime = Date(timeIntervalSince1970: 100)
            model.lastQuotaRefreshTime = previousTime
            XCTAssertTrue(model.beginBatchRefresh(providers: [.glm]))
            defer { model.endBatchRefresh(providers: [.glm]) }

            var entered = false
            let waiting = Task {
                entered = true
                await refreshBatch(model, unified: unified, wait: true)
            }
            // 同在 MainActor 上，任务进入后会在真实预约等待中挂起；此时取消不需要真实计时或网络夹具。
            while !entered { await Task.yield() }
            waiting.cancel()
            await waiting.value

            XCTAssertTrue(model.isQuotaRefreshDueForPolling(), "取消预约不能消耗下一次有效批次的节流时间")
            XCTAssertEqual(model.lastQuotaRefreshTime, previousTime)
            XCTAssertEqual(model.refreshingProviders, [.glm])
            XCTAssertTrue(model.refreshingAccounts.isEmpty)
            XCTAssertTrue(model.isRefreshBlocked(for: QuotaAccountID(provider: .glm, accountKey: "fixture")))
        }
    }
}
