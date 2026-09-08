import XCTest
import SQLite3
@testable import Quotio

/// 使用隔离的日账本和 SQLite 回归历史迁移及上游统计口径，不读取或消费真实 CPA 队列。
final class CPAUsageDashboardTests: XCTestCase {
    private var calendar: Calendar {
        var value = Calendar(identifier: .gregorian)
        value.timeZone = .current
        return value
    }
    private var day: Date { calendar.startOfDay(for: Date(timeIntervalSince1970: 1_783_500_000)) }

    private func directory() throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: url) }
        return url
    }

    private func record(_ id: String, provider: String = "p", model: String = "m", timestamp: Date? = nil,
                        failed: Bool = false, context: CPAUsageContext? = nil) -> UsageRecord {
        UsageRecord(timestamp: timestamp ?? day.addingTimeInterval(3600), provider: provider, model: model,
                    requestID: id, failed: failed, latencyMilliseconds: 300,
                    tokens: .init(input: 100, output: 20, total: 120), context: context)
    }

    private func saveHistory(_ records: [UsageRecord], url: URL) throws {
        var buckets: [String: UsageBucket] = [:]
        for record in records {
            var bucket = UsageBucket(day: calendar.startOfDay(for: record.timestamp), provider: record.provider, model: record.model)
            bucket = buckets[bucket.id] ?? bucket
            bucket.add(record); buckets[bucket.id] = bucket
        }
        var snapshot = UsageLedgerSnapshot()
        snapshot.buckets = Array(buckets.values)
        snapshot.firstCollectedAt = day
        snapshot.lastCollectedAt = day.addingTimeInterval(12 * 3600)
        try JSONEncoder().encode(snapshot).write(to: url)
    }

    func testOldDailyHistoryRestoresOverviewTrendAndRankingWithoutInventingEvents() async throws {
        let url = try directory().appendingPathComponent("ledger.json")
        try saveHistory([record("old-1"), record("old-2", provider: "other")], url: url)
        let ledger = UsageLedger(url: url, calendar: calendar)
        let report = try await ledger.queryDashboard(CPAUsageQuery(), dimension: .model, metric: .tokens, limit: 8)
        XCTAssertEqual(report.summary.metrics.requests, 2)
        XCTAssertEqual(report.summary.metrics.tokens, 240)
        XCTAssertEqual(report.historicalRequests, 2)
        XCTAssertEqual(report.categories.count, 1)
        XCTAssertEqual(report.categories.first?.tokens, 240)
        XCTAssertEqual(report.trend.reduce(0) { $0 + $1.tokens }, 240)
        XCTAssertFalse(report.hourly)
        XCTAssertNil(report.summary.metrics.rpm, "日桶无法重建首末请求的精确跨度")
        XCTAssertEqual(report.summary.models.map(\.id), ["m"])
        let events = try await ledger.queryEvents(CPAUsageQuery())
        XCTAssertEqual(events.metrics.requests, 0, "日汇总不能伪造明细")
    }

    func testHistoryAndNewEventsStayConsistentAfterRefreshAndReopen() async throws {
        let url = try directory().appendingPathComponent("ledger.json")
        try saveHistory([record("old")], url: url)
        let ledger = UsageLedger(url: url, calendar: calendar)
        _ = try await ledger.ingest([record("new")], collectedAt: day.addingTimeInterval(13 * 3600))
        for reader in [ledger, UsageLedger(url: url, calendar: calendar)] {
            let report = try await reader.queryDashboard(CPAUsageQuery(), dimension: .model, metric: .tokens, limit: 8)
            XCTAssertEqual(report.summary.metrics.requests, 2)
            XCTAssertEqual(report.summary.metrics.tokens, 240)
            XCTAssertEqual(report.historicalRequests, 1, "已入索引的新事件必须从日桶中扣除")
            XCTAssertEqual(report.trend.reduce(0) { $0 + $1.requests }, 2)
            XCTAssertEqual(report.categories.reduce(0) { $0 + $1.requests }, 2)
        }
    }

    func testIndexedOnlyLedgerDoesNotReclassifyEventsAsHistorical() async throws {
        let url = try directory().appendingPathComponent("ledger.json")
        let ledger = UsageLedger(url: url, calendar: calendar)
        _ = try await ledger.ingest([record("one"), record("two")], collectedAt: day.addingTimeInterval(7200))
        let reopened = UsageLedger(url: url, calendar: calendar)
        let report = try await reopened.queryDashboard(CPAUsageQuery(), dimension: .provider, metric: .requests, limit: 8)
        XCTAssertEqual(report.historicalRequests, 0)
        XCTAssertEqual(report.summary.metrics.requests, 2)
    }

    func testTimeZoneChangeDoesNotSubtractAnEventFromOverlappingDaysTwice() async throws {
        let url = try directory().appendingPathComponent("ledger.json")
        let utcDay = try XCTUnwrap(ISO8601DateFormatter().date(from: "2026-09-07T00:00:00Z"))
        var old = UsageBucket(day: utcDay, provider: "p", model: "m")
        old.requests = 100; old.totalTokens = 10_000
        var snapshot = UsageLedgerSnapshot()
        snapshot.buckets = [old]; snapshot.lastCollectedAt = utcDay.addingTimeInterval(3600)
        try JSONEncoder().encode(snapshot).write(to: url)
        var beijing = Calendar(identifier: .gregorian)
        beijing.timeZone = try XCTUnwrap(TimeZone(secondsFromGMT: 8 * 3600))
        let ledger = UsageLedger(url: url, calendar: beijing)
        let event = UsageRecord(timestamp: utcDay.addingTimeInterval(7200), provider: "p", model: "m",
                                requestID: "after-timezone-change", tokens: .init(total: 50))
        _ = try await ledger.ingest([event], collectedAt: utcDay.addingTimeInterval(7201))
        // 两个日桶的绝对时间窗口相交，但事件只属于写入时记录的北京时间日桶。
        for reader in [ledger, UsageLedger(url: url, calendar: beijing)] {
            let report = try await reader.queryDashboard(CPAUsageQuery(), dimension: .model, metric: .tokens, limit: 8)
            XCTAssertEqual(report.summary.metrics.requests, 101)
            XCTAssertEqual(report.summary.metrics.tokens, 10_050)
            XCTAssertEqual(report.historicalRequests, 100)
        }
    }

    func testExistingSQLiteSchemaUpgradesWithoutLosingEvents() async throws {
        let root = try directory()
        let oldURL = root.appendingPathComponent("usage-events.sqlite")
        do {
            let store = CPAUsageEventStore(url: oldURL)
            try store.ingest([CPAUsageEvent(record: record("existing"))], collectedAt: day)
        }
        do {
            // 构造真实旧命名和缺 ledger_day 的 schema；生产迁移只能读取这个库。
            let old = AnalyticsDatabase(url: oldURL)
            try old.execute("ALTER TABLE cpa_events RENAME TO events")
            try old.execute("DROP INDEX cpa_events_ledger_day")
            try old.execute("ALTER TABLE events DROP COLUMN ledger_day")
            try old.execute("ALTER TABLE cpa_model_prices RENAME TO model_prices")
            try old.execute("ALTER TABLE cpa_metadata RENAME TO metadata")
        }
        let original = try Data(contentsOf: oldURL)
        let ledger = UsageLedger(url: root.appendingPathComponent("ledger.json"), calendar: calendar)
        let report = try await ledger.queryEvents(CPAUsageQuery())
        let snapshot = try await ledger.load()
        XCTAssertEqual(report.metrics.requests, 1)
        XCTAssertEqual(snapshot.totals.requests, 1)
        XCTAssertEqual(try Data(contentsOf: oldURL), original, "迁移不能改写旧库 schema 或数据")
    }

    func testPartialDayAndUnsupportedFiltersReportIncompleteHistory() async throws {
        let url = try directory().appendingPathComponent("ledger.json")
        try saveHistory([record("old")], url: url)
        let ledger = UsageLedger(url: url, calendar: calendar)
        for query in [CPAUsageQuery(start: day.addingTimeInterval(3600), end: day.addingTimeInterval(7200)),
                      CPAUsageQuery(source: "known-source"), CPAUsageQuery(apiKey: "known-key"),
                      CPAUsageQuery(outcome: .failed)] {
            let report = try await ledger.queryDashboard(query, dimension: .model, metric: .tokens, limit: 8)
            XCTAssertEqual(report.historicalRequests, 0)
            XCTAssertEqual(report.omittedHistoricalRequests, 1)
        }
        let complete = try await ledger.queryDashboard(CPAUsageQuery(start: day, end: day.addingTimeInterval(13 * 3600)),
                                                       dimension: .model, metric: .tokens, limit: 8)
        XCTAssertEqual(complete.historicalRequests, 1)
        XCTAssertEqual(complete.omittedHistoricalRequests, 0)
        let unrelated = try await ledger.queryDashboard(CPAUsageQuery(provider: "different"), dimension: .model, metric: .tokens, limit: 8)
        XCTAssertEqual(unrelated.omittedHistoricalRequests, 0)
        XCTAssertEqual(unrelated.summary.metrics.requests, 0)
    }

    func testHistoricalFailuresDoNotBecomeKnownCancellationsOrSuccessRate() async throws {
        let url = try directory().appendingPathComponent("ledger.json")
        try saveHistory([record("success"), record("failure", failed: true)], url: url)
        let report = try await UsageLedger(url: url).queryDashboard(CPAUsageQuery(), dimension: .model, metric: .tokens, limit: 8)
        XCTAssertEqual(report.summary.metrics.unclassifiedFailures, 1)
        XCTAssertNil(report.summary.metrics.successRate)
        XCTAssertNil(report.summary.metrics.cacheReadRate)
    }

    func testUpstreamMetricsAndSixFiltersUseTheSameEvents() throws {
        let store = CPAUsageEventStore(url: try directory().appendingPathComponent("events.sqlite"))
        var context = CPAUsageContext()
        context.sourceID = "source"; context.apiKeyID = "key"; context.cacheRead = 40; context.cacheWrite = 0; context.ttft = 100
        var canceled = context; canceled.canceled = true
        let records = [record("ok", context: context), record("failed", failed: true, context: context),
                       record("cancel", failed: true, context: canceled), record("other", provider: "other", model: "other")]
        try store.ingest(records.map { CPAUsageEvent(record: $0) }, collectedAt: day)
        let query = CPAUsageQuery(start: day, end: day.addingTimeInterval(7200), provider: "p", model: "m", source: "source", apiKey: "key")
        let report = try store.dashboard(query, dimension: .model, metric: .tokens, limit: 8)
        let metrics = report.summary.metrics
        XCTAssertEqual(metrics.requests, 3)
        XCTAssertEqual(metrics.successes, 1); XCTAssertEqual(metrics.failures, 1); XCTAssertEqual(metrics.canceled, 1)
        XCTAssertEqual(metrics.successRate, 50)
        XCTAssertEqual(metrics.cacheReadRate, 40)
        XCTAssertEqual(metrics.tps, 100)
        XCTAssertEqual(metrics.rpm ?? -1, 3.0 / 120, accuracy: 0.000001)
        XCTAssertEqual(metrics.tpm, 3)
        XCTAssertEqual(report.trend.reduce(0) { $0 + $1.tokens }, metrics.tokens)
        XCTAssertEqual(report.categories.reduce(0) { $0 + $1.tokens }, metrics.tokens)
        var onlyCanceled = query; onlyCanceled.outcome = .canceled
        XCTAssertEqual(try store.query(onlyCanceled).events.map(\.outcome), [.canceled])
    }

    func testModelGroupingDoesNotImplicitlyFilterAProviderWhenOpeningRecords() throws {
        let store = CPAUsageEventStore(url: try directory().appendingPathComponent("events.sqlite"))
        try store.ingest([record("a"), record("b", provider: "other")].map { CPAUsageEvent(record: $0) }, collectedAt: day)
        let report = try store.dashboard(CPAUsageQuery(), dimension: .model, metric: .tokens, limit: 8)
        XCTAssertEqual(report.categories.count, 1)
        let category = try XCTUnwrap(report.categories.first)
        XCTAssertEqual(category.requests, 2)
        let selection = category.selection(from: CPAUsageSelection(range: .all), dimension: .model)
        XCTAssertTrue(selection.provider.isEmpty)
        XCTAssertEqual(try store.query(selection.query(now: day, page: 1, pageSize: 50)).metrics.requests, 2)
    }

    func testRawCacheAliasesMatchUpstreamAndSurviveRoundTrip() throws {
        let data = Data(#"[{"timestamp":"2026-07-08T01:00:00Z","provider":"claude","tokens":{"input_tokens":12,"output_tokens":4,"cached_tokens":10,"cache_read_tokens":5,"cache_creation_tokens":3,"total_tokens":16}},{"timestamp":"2026-07-08T01:00:00Z","tokens":{"input_tokens":100,"cached_tokens":5,"cache_tokens":40}},{"timestamp":"2026-07-08T01:00:00Z","tokens":{"input_tokens":100}}]"#.utf8)
        let records = try JSONDecoder().decode(UsageQueueBatch.self, from: data).records
        XCTAssertEqual(records.count, 3)
        XCTAssertEqual(records[0].tokens.cached, 10)
        XCTAssertEqual(records[0].tokens.input, 12, "缓存总量不能替代显式读写分量参与输入归一")
        XCTAssertEqual(records[1].context?.cacheRead, 40)
        XCTAssertEqual(records[1].context?.cacheWrite, 0)
        XCTAssertEqual(records[2].context?.cacheRead, 0)
        XCTAssertEqual(records[2].context?.cacheWrite, 0)
        XCTAssertEqual(try JSONDecoder().decode([UsageRecord].self, from: JSONEncoder().encode(records)), records)
    }
}
