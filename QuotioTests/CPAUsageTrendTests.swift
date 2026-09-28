import XCTest
@testable import QuotioPlus

/// 从真实 SQLite 查询到趋势结果验证分量，不使用生产数据库或按总量反推输入、输出、缓存。
final class CPAUsageTrendTests: XCTestCase {
    private var calendar: Calendar { Calendar.current }
    private var day: Date { calendar.startOfDay(for: Date(timeIntervalSince1970: 1_783_500_000)) }

    private func directory() throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: url) }
        return url
    }

    private func record(_ id: String, date: Date, provider: String = "p", failed: Bool = false) -> UsageRecord {
        UsageRecord(timestamp: date, provider: provider, model: "m", requestID: id, failed: failed,
                    tokens: .init(input: 100, output: 20, cached: 60, total: 120))
    }

    private func assertComponents(_ report: CPAUsageDashboardReport, file: StaticString = #filePath, line: UInt = #line) {
        let metrics = report.summary.metrics
        XCTAssertEqual(report.trend.reduce(0) { $0 + $1.requests }, metrics.requests, file: file, line: line)
        XCTAssertEqual(report.trend.reduce(0) { $0 + $1.tokens }, metrics.tokens, file: file, line: line)
        XCTAssertEqual(report.trend.reduce(0) { $0 + $1.input }, metrics.input, file: file, line: line)
        XCTAssertEqual(report.trend.reduce(0) { $0 + $1.output }, metrics.output, file: file, line: line)
        XCTAssertEqual(report.trend.reduce(0) { $0 + $1.cached }, metrics.cached, file: file, line: line)
    }

    func testHourlySeriesUseSameFiltersAndFillEmptyIntervalsWithoutDoubleCountingCache() throws {
        let store = CPAUsageEventStore(url: try directory().appendingPathComponent("analytics.sqlite"))
        let records = [record("one", date: day.addingTimeInterval(300)),
                       record("two", date: day.addingTimeInterval(7500)),
                       record("other-provider", date: day.addingTimeInterval(300), provider: "other"),
                       record("failed", date: day.addingTimeInterval(300), failed: true)]
        try store.ingest(records.map { CPAUsageEvent(record: $0) }, collectedAt: day.addingTimeInterval(10800))
        let query = CPAUsageQuery(start: day, end: day.addingTimeInterval(10800), provider: "p", outcome: .success)
        let report = try store.dashboard(query, dimension: .model, metric: .tokens, limit: 8)
        XCTAssertTrue(report.hourly)
        XCTAssertEqual(report.summary.metrics.requests, 2)
        XCTAssertEqual(report.trend.count, 4)
        assertComponents(report)
        let empty = try XCTUnwrap(report.trend.first { $0.date == day.addingTimeInterval(3600) })
        XCTAssertTrue(CPAUsageTrendSeries.allCases.allSatisfy { $0.value(in: empty) == 0 })
        let first = try XCTUnwrap(report.trend.first)
        XCTAssertEqual(CPAUsageTrendSeries.total.value(in: first), 120, "缓存属于输入，不应把总量变成 180")
        XCTAssertEqual(CPAUsageTrendSeries.input.value(in: first), 100)
        XCTAssertEqual(CPAUsageTrendSeries.output.value(in: first), 20)
        XCTAssertEqual(CPAUsageTrendSeries.cached.value(in: first), 60)
    }

    func testLongEventHistoryKeepsEveryComponentDuringCompression() throws {
        let store = CPAUsageEventStore(url: try directory().appendingPathComponent("analytics.sqlite"))
        let events = (0..<481).map { index in
            CPAUsageEvent(record: record("event-\(index)", date: calendar.date(byAdding: .day, value: index, to: day)!))
        }
        try store.ingest(events, collectedAt: events.last!.timestamp)
        let report = try store.dashboard(CPAUsageQuery(), dimension: .model, metric: .tokens, limit: 8)
        XCTAssertLessThanOrEqual(report.trend.count, 240)
        XCTAssertEqual(report.summary.metrics.requests, 481)
        assertComponents(report)
    }

    func testHistoricalMergeKeepsComponentsBeforeCompressionAndAfterReopen() async throws {
        let url = try directory().appendingPathComponent("legacy.json")
        var snapshot = UsageLedgerSnapshot()
        snapshot.buckets = (0..<381).map { index in
            var bucket = UsageBucket(day: calendar.date(byAdding: .day, value: index, to: day)!, provider: "p", model: "m")
            bucket.requests = 1; bucket.inputTokens = 100; bucket.outputTokens = 20
            bucket.cachedTokens = 60; bucket.totalTokens = 120
            return bucket
        }
        snapshot.lastCollectedAt = snapshot.buckets.last!.day.addingTimeInterval(60)
        try JSONEncoder().encode(snapshot).write(to: url)
        let ledger = UsageLedger(url: url)
        let newer = record("new", date: snapshot.buckets.last!.day.addingTimeInterval(120))
        _ = try await ledger.ingest([newer], collectedAt: newer.timestamp)
        for reader in [ledger, UsageLedger(url: url)] {
            let report = try await reader.queryDashboard(CPAUsageQuery(), dimension: .model, metric: .tokens, limit: 8)
            XCTAssertEqual(report.historicalRequests, 381)
            XCTAssertEqual(report.summary.metrics.requests, 382)
            XCTAssertLessThanOrEqual(report.trend.count, 240)
            assertComponents(report)
        }
    }
}
