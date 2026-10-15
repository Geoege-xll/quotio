import AppKit
import SwiftUI
import XCTest
import Observation
@testable import QuotioPlus

/// 使用手动操作状态和临时 SQL 账本验证交互，不连接用户 CPA、不改用户偏好。
@MainActor
final class RefreshInteractionTests: XCTestCase {
    func testOnlyUserActionStartsProgressAndDuplicateClicksAreCoalesced() async {
        let state = ManualRefreshState()
        XCTAssertFalse(state.isRefreshing)
        var finish: CheckedContinuation<Void, Never>?
        let pending = Task { await state.perform { await withCheckedContinuation { finish = $0 } } }
        while finish == nil { await Task.yield() }
        XCTAssertTrue(state.isRefreshing)
        var duplicateCalls = 0
        await state.perform { duplicateCalls += 1 }
        XCTAssertEqual(duplicateCalls, 0)
        finish?.resume()
        await pending.value
        XCTAssertFalse(state.isRefreshing)
        await state.perform { duplicateCalls += 1 }
        XCTAssertEqual(duplicateCalls, 1, "完成之后仍可再次手动刷新")
    }

    func testCanceledManualOperationReleasesProgressState() async {
        let state = ManualRefreshState()
        let pending = Task {
            await state.perform { try? await Task.sleep(for: .seconds(30)) }
        }
        while !state.isRefreshing { await Task.yield() }
        pending.cancel()
        await pending.value
        XCTAssertFalse(state.isRefreshing)
    }

    func testPageRefreshOwnershipIncludesBothLegacyAccountRoutes() {
        for page in [NavigationPage.providers, .quota, .analytics, .dashboard] {
            XCTAssertTrue(page.providesDataRefreshAction)
        }
        XCTAssertFalse(NavigationPage.settings.providesDataRefreshAction)
        XCTAssertFalse(NavigationPage.agents.providesDataRefreshAction)
    }

    func testManualBatchWaitsForConflictStartedDuringDirectoryRead() async {
        var resumeDirectory: CheckedContinuation<Void, Never>?
        var occupied = false
        var attempted = false
        var executed = 0
        let user = Task {
            // 可控地暂停目录读取，随后后台批次先占用真实 claim 对应的槽位。
            await withCheckedContinuation { resumeDirectory = $0 }
            let acquired = await QuotaRefreshAvailability.acquire(wait: true) {
                attempted = true
                guard !occupied else { return false }
                occupied = true
                return true
            }
            if acquired { executed += 1; occupied = false }
        }
        while resumeDirectory == nil { await Task.yield() }
        occupied = true
        resumeDirectory?.resume()
        while !attempted { await Task.yield() }
        XCTAssertEqual(executed, 0)
        occupied = false
        await user.value
        XCTAssertEqual(executed, 1, "实际预约处等待，不能因目录读取期间的后台冲突丢失点击")
    }

    func testBackgroundBatchCoalescesAndCanceledManualBatchDoesNotAcquire() async {
        var occupied = true
        var attempted = false
        let background = await QuotaRefreshAvailability.acquire(wait: false) { !occupied }
        XCTAssertFalse(background)
        let user = Task {
            await QuotaRefreshAvailability.acquire(wait: true) {
                attempted = true
                return !occupied
            }
        }
        while !attempted { await Task.yield() }
        user.cancel()
        occupied = false
        let acquired = await user.value
        XCTAssertFalse(acquired, "取消后的用户任务不应在下次轮询预约批次")
    }

    private func store() throws -> UsageStatisticsStore {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: directory) }
        return UsageStatisticsStore(ledger: UsageLedger(databaseURL: directory.appendingPathComponent("usage.sqlite")))
    }

    func testIdenticalBackgroundReportDoesNotNotifyChartObservers() async throws {
        let model = CPAUsageDashboardViewModel(), store = try store()
        let query = CPAUsageDashboardViewModel.Query(selection: .init(range: .hours24), dimension: .model,
                                                     metric: .tokens, limit: 8, active: true)
        let loaded = await model.load(query, store: store)
        XCTAssertTrue(loaded)
        let unchanged = expectation(description: "相同后台报表不重绘图表")
        unchanged.isInverted = true
        withObservationTracking { _ = model.result } onChange: { unchanged.fulfill() }
        let reloaded = await model.load(query, store: store)
        XCTAssertTrue(reloaded)
        await fulfillment(of: [unchanged], timeout: 0.05)
        XCTAssertNotNil(model.result)
    }

    func testManualRefreshKeepsExistingReportAndFilterUntilNewQueryCompletes() async throws {
        let model = CPAUsageDashboardViewModel(), store = try store()
        let selection = CPAUsageSelection(range: .days7, provider: "fixture")
        let query = CPAUsageDashboardViewModel.Query(selection: selection, dimension: .provider,
                                                     metric: .requests, limit: 48, active: true)
        let loaded = await model.load(query, store: store)
        XCTAssertTrue(loaded)
        let report = model.result
        model.requestRefresh()
        XCTAssertEqual(model.result, report, "点击刷新不清空图表或触发首屏占位")
        XCTAssertEqual(model.refreshRevision, 1)
        let manual = CPAUsageDashboardViewModel.Query(selection: selection, dimension: .provider,
            metric: .requests, limit: 48, active: true, refreshRevision: model.refreshRevision)
        XCTAssertNotEqual(manual, query)
        XCTAssertEqual(manual.selection, selection)
        let reloaded = await model.load(manual, store: store)
        XCTAssertTrue(reloaded)
        XCTAssertNotNil(model.result)
        XCTAssertNil(model.errorKey)
    }

}
