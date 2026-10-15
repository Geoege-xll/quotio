import XCTest
@testable import QuotioPlus

/// 只替换目录和用量的外部等待步骤，仍经过主类真实互斥、来源复核与受保护时间写入。
/// 测试宿主仅设置内存运行状态；不启停进程、不读取账本、不访问真实 CPA。
@MainActor
final class DashboardRefreshSessionTests: XCTestCase {
    private final class StepGate {
        let started: XCTestExpectation
        private var continuation: CheckedContinuation<Void, Never>?
        private var released = false
        init(started: XCTestExpectation) { self.started = started }
        func wait() async {
            if released { return }
            await withCheckedContinuation {
                continuation = $0
                started.fulfill()
            }
        }
        func release() {
            released = true
            continuation?.resume()
            continuation = nil
        }
    }

    private func fixture() throws -> QuotaViewModel {
        let suite = "quotio-dashboard-session-" + UUID().uuidString
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defaults.set(OperatingMode.localProxy.rawValue, forKey: "operatingMode")
        let notifications = NotificationManager(testDefaults: defaults, notificationSink: { _ in })
        let model = QuotaViewModel(
            directAuthService: DirectAuthFileService(authDirectory: FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)),
            startsBackgroundServices: false, modeManager: OperatingModeManager(defaults: defaults),
            menuBarSettings: MenuBarSettingsManager(defaults: defaults), refreshSettings: RefreshSettingsManager(defaults: defaults),
            warmupSettings: WarmupSettingsManager(defaults: defaults), notificationManager: notifications
        )
        let manager = model.proxyManager, originalStatus = manager.proxyStatus, originalSession = manager.runtimeSessionID
        manager.setRuntimeStateForTesting(running: true, sessionID: UUID())
        // 管理客户端只用于身份比较；所有 I/O 都由生产协调方法的步骤闭包隔离。
        let client = ManagementAPIClient(baseURL: "https://dashboard-fixture.invalid" + ManagementAPIClient.managementPath, authKey: "fixture")
        model.setAuthImportClientForTesting(client)
        addTeardownBlock { @MainActor in
            manager.setRuntimeStateForTesting(running: originalStatus.running, sessionID: originalSession)
            await client.invalidate()
            defaults.removePersistentDomain(forName: suite)
        }
        return model
    }

    private func changeSource(_ change: String, model: QuotaViewModel) {
        switch change {
        case "stop": model.proxyManager.setRuntimeStateForTesting(running: false, sessionID: model.proxyManager.runtimeSessionID)
        case "restart": model.proxyManager.setRuntimeStateForTesting(running: true, sessionID: UUID())
        case "client": model.setAuthImportClientForTesting(nil)
        default: model.modeManager.setMode(.monitor)
        }
    }

    func testSuccessfulRefreshRecordsTimeAndDuplicateDoesNotOwnState() async throws {
        let model = try fixture(), originalID = model.dashboardRefreshID
        let gate = StepGate(started: expectation(description: "原刷新等待目录"))
        var usageCalls = 0
        let pending = Task { await model.refreshDashboardForTesting(refreshData: { await gate.wait(); return true }, refreshUsage: { usageCalls += 1; return true }) }
        await fulfillment(of: [gate.started], timeout: 3)
        XCTAssertTrue(model.isRefreshingDashboard)
        let currentID = model.dashboardRefreshID
        XCTAssertNotEqual(currentID, originalID)
        await model.refreshDashboardForTesting(refreshData: { XCTFail("重复点击不能进入读取"); return true }, refreshUsage: { XCTFail("重复点击不能调用用量"); return true })
        XCTAssertEqual(model.dashboardRefreshID, currentID)
        XCTAssertTrue(model.isRefreshingDashboard)
        gate.release()
        await pending.value
        XCTAssertEqual(usageCalls, 1)
        XCTAssertNotNil(model.dashboardRefreshTime)
        XCTAssertFalse(model.isRefreshingDashboard)
    }

    func testSourceChangesAfterDirectoryDoNotEnterUsageOrRecordTime() async throws {
        for change in ["stop", "restart", "client", "mode"] {
            let model = try fixture()
            let gate = StepGate(started: expectation(description: change + "：等待目录"))
            var usageCalls = 0
            let pending = Task { await model.refreshDashboardForTesting(refreshData: { await gate.wait(); return true }, refreshUsage: { usageCalls += 1; return true }) }
            await fulfillment(of: [gate.started], timeout: 3)
            changeSource(change, model: model)
            gate.release()
            await pending.value
            XCTAssertEqual(usageCalls, 0, change)
            XCTAssertNil(model.dashboardRefreshTime, change)
            XCTAssertFalse(model.isRefreshingDashboard, change)
        }
    }

    func testSourceChangesDuringUsagePreservePreviousSuccessfulTime() async throws {
        for change in ["stop", "restart", "client", "mode"] {
            let model = try fixture()
            await model.refreshDashboardForTesting(refreshData: { true }, refreshUsage: { true })
            let previousTime = try XCTUnwrap(model.dashboardRefreshTime)
            let gate = StepGate(started: expectation(description: change + "：等待用量"))
            let pending = Task { await model.refreshDashboardForTesting(refreshData: { true }, refreshUsage: { await gate.wait(); return true }) }
            await fulfillment(of: [gate.started], timeout: 3)
            changeSource(change, model: model)
            gate.release()
            await pending.value
            XCTAssertEqual(model.dashboardRefreshTime, previousTime, change)
            XCTAssertFalse(model.isRefreshingDashboard, change)
        }
    }

    func testCancellationAtEitherWaitCannotRecordCompletionTime() async throws {
        for pauseAtUsage in [false, true] {
            let model = try fixture()
            let gate = StepGate(started: expectation(description: "等待后取消"))
            var usageCalls = 0
            let pending = Task {
                await model.refreshDashboardForTesting(refreshData: {
                    if !pauseAtUsage { await gate.wait() }
                    return true
                }, refreshUsage: {
                    usageCalls += 1
                    if pauseAtUsage { await gate.wait() }
                    return true
                })
            }
            await fulfillment(of: [gate.started], timeout: 3)
            pending.cancel()
            gate.release()
            await pending.value
            XCTAssertEqual(usageCalls, pauseAtUsage ? 1 : 0)
            XCTAssertNil(model.dashboardRefreshTime)
            XCTAssertFalse(model.isRefreshingDashboard)
        }
    }

    func testFailedOrSupersededDirectoryCannotBorrowClearedGlobalErrorAsSuccess() async throws {
        let model = try fixture()
        var usageCalls = 0
        await model.refreshDashboardForTesting(refreshData: { false }, refreshUsage: {
            usageCalls += 1
            model.errorMessage = nil
            return true
        })
        XCTAssertEqual(usageCalls, 1, "同会话仍保留原独立用量刷新步骤")
        XCTAssertNil(model.dashboardRefreshTime)
        XCTAssertFalse(model.isRefreshingDashboard)
        await model.refreshDashboardForTesting(refreshData: { true }, refreshUsage: { model.errorMessage = "current failure"; return true })
        XCTAssertNil(model.dashboardRefreshTime)
        XCTAssertFalse(model.isRefreshingDashboard)
        model.errorMessage = nil
        await model.refreshDashboardForTesting(refreshData: { true }, refreshUsage: { false })
        XCTAssertNil(model.dashboardRefreshTime, "用量刷新失败或被跳过同样不能记录成功")
        XCTAssertFalse(model.isRefreshingDashboard)
    }
}
