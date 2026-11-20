import XCTest
import SQLite3
@testable import QuotioPlus

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

    func testHeatmapBucketsIgnoreShortTimeWindowButRespectNonTimeFiltersAndHistory() async throws {
        let url = try directory().appendingPathComponent("ledger.json")
        let today = calendar.startOfDay(for: Date())
        let pastDay = try XCTUnwrap(calendar.date(byAdding: .day, value: -14, to: today))
        try saveHistory([
            record("old-p-m", provider: "p", model: "m", timestamp: pastDay.addingTimeInterval(3600)),
            record("old-other", provider: "other", model: "m2", timestamp: pastDay.addingTimeInterval(7200))
        ], url: url)

        let ledger = UsageLedger(url: url, calendar: calendar)
        var context = CPAUsageContext()
        context.sourceID = "cli-a"
        context.apiKeyID = "key-1"
        _ = try await ledger.ingest([
            record("today-p-m", provider: "p", model: "m", timestamp: today.addingTimeInterval(3600), context: context),
            record("today-failed", provider: "p", model: "m", timestamp: today.addingTimeInterval(4200), failed: true, context: context),
            record("today-other", provider: "other", model: "m2", timestamp: today.addingTimeInterval(5000))
        ], collectedAt: today.addingTimeInterval(5100))

        // 仅筛选今日且按 provider="p" 过滤：摘要只统计今日；热力图仍覆盖 52 周内的历史 + 今日且只保留 provider="p"。
        let todayProviderQuery = CPAUsageQuery(start: today, end: today.addingTimeInterval(86400), provider: "p")
        let providerReport = try await ledger.queryDashboard(todayProviderQuery, dimension: .model, metric: .requests, limit: 8)
        XCTAssertEqual(providerReport.summary.metrics.requests, 2)
        XCTAssertEqual(providerReport.heatmapBuckets.reduce(0) { $0 + $1.requests }, 3,
                       "热力图应保留 52 周内的历史与今日请求，并按 provider 过滤")
        XCTAssertTrue(providerReport.heatmapBuckets.allSatisfy { $0.provider == "p" })

        // 当筛选 source / apiKey / outcome 时，历史日桶不包含对应维度应被排除，仅保留符合筛选的明细事件。
        let sourceReport = try await ledger.queryDashboard(
            CPAUsageQuery(start: today, end: today.addingTimeInterval(86400), source: "cli-a"),
            dimension: .model, metric: .requests, limit: 8
        )
        XCTAssertEqual(sourceReport.heatmapBuckets.reduce(0) { $0 + $1.requests }, 2)

        let failedReport = try await ledger.queryDashboard(
            CPAUsageQuery(start: today, end: today.addingTimeInterval(86400), outcome: .failed),
            dimension: .model, metric: .requests, limit: 8
        )
        XCTAssertEqual(failedReport.heatmapBuckets.reduce(0) { $0 + $1.requests }, 1)
    }

    func testCostRanksBeforeLimitAndAnnualBucketsKeepFullLocalDays() throws {
        let store = CPAUsageEventStore(url: try directory().appendingPathComponent("events.sqlite"))
        let early = day.addingTimeInterval(3600)
        let late = day.addingTimeInterval(7200)
        let cheap = (0..<9).map { record("cheap-\($0)", model: "cheap-\($0)", timestamp: early) }
        let input = cheap + [record("costly", model: "z-costly", timestamp: early),
                             record("later", model: "z-costly", timestamp: late),
                             record("other", provider: "other", model: "z-costly", timestamp: early)]
        try store.ingest(input.map { CPAUsageEvent(record: $0) }, collectedAt: late)
        for n in 0..<9 { try store.savePrice(CPAModelPrice(model: "cheap-\(n)", input: 1, output: 1)) }
        try store.savePrice(CPAModelPrice(model: "z-costly", input: 10, output: 10))
        let exact = CPAUsageQuery(start: day, end: early, provider: "p")
        let report = try store.dashboard(exact, dimension: .model, metric: .cost, limit: 8, calendar: calendar, now: late)
        let pricing = try store.pricing(exact)
        XCTAssertEqual(report.summary.metrics.requests, 10)
        XCTAssertEqual(report.categories.count, 8)
        XCTAssertTrue(report.hasMoreCategories)
        XCTAssertEqual(report.categories.first?.key, "z-costly")
        XCTAssertEqual(try XCTUnwrap(report.estimatedCost.amount), try XCTUnwrap(pricing.estimatedCost), accuracy: 1e-12)
        XCTAssertFalse(report.estimatedCost.isPartial)
        let costlyDay = try XCTUnwrap(report.heatmapBuckets.first { $0.model == "z-costly" })
        XCTAssertEqual(costlyDay.requests, 2, "非时间条件仍生效，晚间同日明细不受精确窗裁剪")
        XCTAssertEqual(try XCTUnwrap(report.heatmapCosts[costlyDay.id]?.amount), 0.0024, accuracy: 1e-12)
        XCTAssertEqual(report.selectedEnd, early)
        XCTAssertEqual(report.heatmapToday, day)
    }

    func testIndexedCostDistinguishesExplicitZeroUnknownAndMissingCacheSplit() throws {
        let store = CPAUsageEventStore(url: try directory().appendingPathComponent("events.sqlite"))
        var cache = CPAUsageContext()
        cache.cacheRead = 40; cache.cacheWrite = 0
        let records = [record("free", model: "free"), record("unpriced", model: "unknown"),
                       record("known-zero", model: "partial"),
                       UsageRecord(timestamp: day.addingTimeInterval(3600), provider: "p", model: "partial",
                                   requestID: "missing-split", tokens: .init(input: 100, output: 20, cached: 40)),
                       record("missing-cache-rate", model: "rate", context: cache)]
        try store.ingest(records.map { CPAUsageEvent(record: $0) }, collectedAt: day)
        for model in ["free", "partial", "rate"] {
            try store.savePrice(CPAModelPrice(model: model, input: 0, output: 0))
        }
        let report = try store.dashboard(CPAUsageQuery(), dimension: .model, metric: .cost, limit: 8, now: day)
        let cost = Dictionary(uniqueKeysWithValues: report.categories.map { ($0.key, $0.cost) })
        XCTAssertEqual(cost["free"], .init(amount: 0))
        XCTAssertEqual(cost["partial"], .init(amount: 0, isPartial: true))
        XCTAssertEqual(cost["rate"], .init(isPartial: true))
        XCTAssertEqual(cost["unknown"], .init(isPartial: true))
        XCTAssertEqual(report.estimatedCost, .init(amount: 0, isPartial: true))
        XCTAssertEqual(Set(report.categories.prefix(2).map(\.key)), ["free", "partial"])
    }

}
