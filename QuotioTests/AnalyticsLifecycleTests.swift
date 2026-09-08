import XCTest
@testable import Quotio

/// 模拟侧栏切页与筛选，验证它们复用正在运行的采集和已完成快照。
@MainActor
final class AnalyticsLifecycleTests: XCTestCase {
    private func makeModel(_ scans: LifecycleUsageScans) throws -> ClientUsageViewModel {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: root) }
        let engine = ClientUsageEngine(url: root.appendingPathComponent("ledger.json"), homeDirectory: root.path,
            environment: [:], scanOverride: { source, _ in try await scans.collect(source) })
        return ClientUsageViewModel(engine: engine)
    }
    private func eventually(_ condition: @escaping @MainActor () -> Bool) async throws {
        let deadline = ContinuousClock.now.advanced(by: .seconds(5))
        while !condition(), ContinuousClock.now < deadline { try await Task.sleep(for: .milliseconds(5)) }
        XCTAssertTrue(condition())
    }

    func testTimeZoneReloadInvalidatesAllHistoryWithoutScanningAgain() async throws {
        let scans = LifecycleUsageScans(), model = try makeModel(scans)
        await scans.release()
        model.refresh()
        try await eventually { !model.isLoading }
        var utc = Calendar(identifier: .gregorian)
        utc.timeZone = TimeZone(secondsFromGMT: 0)!
        var beijing = utc
        beijing.timeZone = TimeZone(secondsFromGMT: 8 * 3600)!
        let eventDate = Date(timeIntervalSince1970: 1000)
        model.reloadPresentation(calendar: utc)
        try await eventually {
            model.presentation(interval: nil, source: nil).statistics.days.first?.day == utc.startOfDay(for: eventDate)
        }
        let before = model.presentation(interval: nil, source: nil)
        model.reloadPresentation(calendar: beijing)
        try await eventually {
            model.presentation(interval: nil, source: nil).statistics.days.first?.day == beijing.startOfDay(for: eventDate)
        }
        let after = model.presentation(interval: nil, source: nil)
        XCTAssertNotEqual(before.statistics.days.first?.day, after.statistics.days.first?.day)
        XCTAssertEqual(before.statistics.totals.totalTokens, after.statistics.totals.totalTokens)
        let count = await scans.count(.codex)
        XCTAssertEqual(count, 1, "只重分现有事实的日期，不能重新采集日志")
    }

    func testLeavingAndReenteringKeepsOneScanAndFreshSnapshot() async throws {
        let scans = LifecycleUsageScans(), model = try makeModel(scans)
        model.start()
        try await eventually { model.snapshot.statuses.count == ClientUsageSource.allCases.count - 1 }
        model.stopAutomaticRefresh()
        XCTAssertTrue(model.isLoading)
        model.start()
        let duringScan = await scans.count(.codex)
        XCTAssertEqual(duringScan, 1)
        await scans.release()
        try await eventually { !model.isLoading }
        model.stopAutomaticRefresh()
        model.start()
        XCTAssertFalse(model.isLoading, "一分钟内重入只恢复展示，不重新采集")
        let completedCount = await scans.count(.codex)
        XCTAssertEqual(completedCount, 1)

        // 反复改变来源、期间只构造或命中内存报表，不访问扫描器。
        for source in ClientUsageSource.allCases {
            _ = model.presentation(interval: nil, source: source)
            _ = model.presentation(interval: DateInterval(start: .distantPast, end: .distantFuture), source: source)
        }
        let filteredCount = await scans.count(.codex)
        XCTAssertEqual(filteredCount, 1)
        XCTAssertEqual(model.presentation(interval: nil, source: nil).statistics.totals.totalTokens, 48)
        model.refreshIfNeeded(now: Date().addingTimeInterval(61))
        XCTAssertTrue(model.isLoading, "过期快照应允许后台刷新")
        try await eventually { !model.isLoading }
        let staleCount = await scans.count(.codex)
        XCTAssertEqual(staleCount, 2)
        XCTAssertEqual(model.presentation(interval: nil, source: nil).statistics.totals.totalTokens, 88,
                       "新快照必须使已缓存的同一筛选失效")
        model.cancel()
    }
}

private actor LifecycleUsageScans {
    private var released = false
    private var counts: [ClientUsageSource: Int] = [:]
    func release() { released = true }
    func count(_ source: ClientUsageSource) -> Int { counts[source, default: 0] }
    func collect(_ source: ClientUsageSource) async throws -> ClientUsageScan {
        counts[source, default: 0] += 1
        while source == .codex && !released { try await Task.sleep(for: .milliseconds(5)) }
        try Task.checkCancellation()
        return ClientUsageScan(source: source, records: [ClientUsageRecord(identity: "stable", source: source,
            timestamp: Date(timeIntervalSince1970: 1000), model: "test", input: counts[source, default: 0] * 10, output: 2)],
            filesScanned: 1, available: true)
    }
}
