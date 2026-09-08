import XCTest
@testable import Quotio

/// 全部输入在临时目录构造，覆盖统一持久化的三方去重、事务回滚与只读迁移约束。
final class CPAUsageSQLiteMigrationTests: XCTestCase {
    private var calendar: Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0)!
        return calendar
    }
    private var day: Date { Date(timeIntervalSince1970: 1_783_468_800) }

    private func directory() throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: url) }
        return url
    }

    private func record(_ id: String?, timestamp: Date? = nil) -> UsageRecord {
        UsageRecord(timestamp: timestamp ?? day.addingTimeInterval(3600), provider: "p", model: "m",
                    requestID: id, tokens: .init(input: 100, output: 20, total: 120))
    }

    private func saveLedger(_ records: [UsageRecord], pending: [CPAUsageEvent] = [], url: URL) throws {
        var buckets: [String: UsageBucket] = [:]
        for record in records {
            let empty = UsageBucket(day: calendar.startOfDay(for: record.timestamp), provider: record.provider, model: record.model)
            var bucket = buckets[empty.id] ?? empty
            bucket.add(record); buckets[bucket.id] = bucket
        }
        var snapshot = UsageLedgerSnapshot()
        snapshot.buckets = Array(buckets.values)
        snapshot.recentRecordIDs = records.compactMap(\.deduplicationID)
        snapshot.firstCollectedAt = day; snapshot.lastCollectedAt = day.addingTimeInterval(7200)
        snapshot.pendingEvents = pending
        try JSONEncoder().encode(snapshot).write(to: url)
    }

    private func saveLegacyDatabase(events: [CPAUsageEvent], price: CPAModelPrice? = nil,
                                    url: URL, hasLedgerDay: Bool = true) throws {
        do {
            let store = CPAUsageEventStore(url: url)
            try store.ingest(events, collectedAt: day, calendar: calendar)
            if let price { try store.savePrice(price) }
        }
        // 用与生产旧版一致的表名和可选列完成 fixture，随后关闭全部写连接。
        let old = AnalyticsDatabase(url: url)
        try old.execute("ALTER TABLE cpa_events RENAME TO events")
        try old.execute("ALTER TABLE cpa_model_prices RENAME TO model_prices")
        try old.execute("ALTER TABLE cpa_metadata RENAME TO metadata")
        if !hasLedgerDay {
            try old.execute("DROP INDEX cpa_events_ledger_day")
            try old.execute("ALTER TABLE events DROP COLUMN ledger_day")
        }
    }

    func testEmptyHeartbeatsDoNotContinuouslyWriteSharedWAL() throws {
        let url = try directory().appendingPathComponent("analytics.sqlite")
        let store = CPAUsageEventStore(url: url), observer = AnalyticsDatabase(url: url)
        try store.ingest([], collectedAt: day)
        let version = try observer.scalarInt("PRAGMA data_version")
        try store.ingest([], collectedAt: day.addingTimeInterval(2))
        try store.ingest([], collectedAt: day.addingTimeInterval(30))
        XCTAssertEqual(try observer.scalarInt("PRAGMA data_version"), version)
        try store.ingest([], collectedAt: day.addingTimeInterval(60))
        XCTAssertNotEqual(try observer.scalarInt("PRAGMA data_version"), version)
        XCTAssertEqual(try store.ledgerSnapshot().lastCollectedAt, day.addingTimeInterval(60))
    }

    func testSQLOnlyMigrationRestoresLatestTimeWhenStartMetadataAlreadyExists() async throws {
        let root = try directory(), oldURL = root.appendingPathComponent("usage-events.sqlite")
        let event = CPAUsageEvent(record: record("late", timestamp: day.addingTimeInterval(7200)))
        try saveLegacyDatabase(events: [event], url: oldURL)
        let old = AnalyticsDatabase(url: oldURL)
        try old.execute("DELETE FROM metadata WHERE key='last_collected'")
        let ledger = UsageLedger(databaseURL: root.appendingPathComponent("analytics.sqlite"), legacyEventURL: oldURL, calendar: calendar)
        let snapshot = try await ledger.load()
        XCTAssertEqual(snapshot.firstCollectedAt, day)
        XCTAssertEqual(snapshot.lastCollectedAt, event.timestamp)
        XCTAssertEqual(snapshot.totals.requests, 1)
    }

    func testMixedLegacySourcesMigrateOnceAndPreservePricesWithoutInventingEvents() async throws {
        let root = try directory(), oldURL = root.appendingPathComponent("ledger.json")
        let history = record("history"), indexed = record("indexed"), pending = record("pending")
        let pendingEvent = CPAUsageEvent(record: pending, ledgerDay: calendar.startOfDay(for: pending.timestamp))
        try saveLedger([history, indexed, pending], pending: [pendingEvent], url: oldURL)
        let price = CPAModelPrice(model: "m", input: 1, output: 2, cacheRead: nil, cacheWrite: 0)
        try saveLegacyDatabase(events: [CPAUsageEvent(record: indexed, ledgerDay: calendar.startOfDay(for: indexed.timestamp)), pendingEvent],
                               price: price, url: root.appendingPathComponent("usage-events.sqlite"))
        let ledger = UsageLedger(url: oldURL, calendar: calendar)
        let snapshot = try await ledger.load()
        let report = try await ledger.queryDashboard(CPAUsageQuery(), dimension: .model, metric: .tokens, limit: 8)
        let records = try await ledger.queryEvents(CPAUsageQuery())
        let prices = try await ledger.queryPricing(CPAUsageQuery())
        XCTAssertEqual(snapshot.totals.requests, 3); XCTAssertEqual(snapshot.totals.totalTokens, 360)
        XCTAssertEqual(report.historicalRequests, 1); XCTAssertEqual(report.summary.metrics.requests, 3)
        XCTAssertEqual(report.trend.reduce(0) { $0 + $1.requests }, 3)
        XCTAssertEqual(report.categories.reduce(0) { $0 + $1.requests }, 3)
        XCTAssertEqual(records.metrics.requests, 2, "历史汇总不能伪造为请求明细")
        XCTAssertEqual(prices.rows.first?.price, price)
        // 旧去重窗口里的历史请求没有明细，升级后重放也不能再加一次。
        let repeated = try await ledger.ingest([history, indexed, pending], collectedAt: day.addingTimeInterval(8000))
        XCTAssertEqual(repeated.totals.requests, 3)
        // 已完成迁移后旧文件只是备份，后续启动不再读取它，采集也不会覆盖它。
        let obsolete = Data("obsolete-backup".utf8)
        try obsolete.write(to: oldURL)
        let reopened = UsageLedger(url: oldURL, calendar: calendar)
        let next = try await reopened.ingest([record("new")], collectedAt: day.addingTimeInterval(9000))
        XCTAssertEqual(next.totals.requests, 4)
        XCTAssertEqual(try Data(contentsOf: oldURL), obsolete)
        let database = AnalyticsDatabase(url: AnalyticsDatabase.storeURL(forLegacyURL: oldURL))
        XCTAssertEqual(try database.scalarInt("SELECT COUNT(*) FROM cpa_events"), 3)
        XCTAssertEqual(try database.scalarInt("SELECT COUNT(*) FROM cpa_historical_buckets"), 1)
        XCTAssertTrue(try database.hasMigration("cpa-unified-storage-v1"))
    }

    func testMigrationFailureRollsBackImportedEventsAndCanBeRetried() async throws {
        let root = try directory(), oldURL = root.appendingPathComponent("ledger.json")
        let databaseURL = AnalyticsDatabase.storeURL(forLegacyURL: oldURL)
        let existing = record("existing")
        try saveLedger([record("history"), existing], url: oldURL)
        try saveLegacyDatabase(events: [CPAUsageEvent(record: existing)], url: root.appendingPathComponent("usage-events.sqlite"))
        let original = try Data(contentsOf: oldURL)
        do { _ = try CPAUsageEventStore(url: databaseURL).query(CPAUsageQuery()) }
        let database = AnalyticsDatabase(url: databaseURL)
        try database.execute("""
            CREATE TRIGGER fail_history BEFORE INSERT ON cpa_historical_buckets
            BEGIN SELECT RAISE(ABORT,'fixture'); END
            """)
        do {
            _ = try await UsageLedger(url: oldURL, calendar: calendar).load()
            XCTFail("历史基线写入失败必须回滚整次迁移")
        } catch {}
        XCTAssertEqual(try database.scalarInt("SELECT COUNT(*) FROM cpa_events"), 0)
        XCTAssertFalse(try database.hasMigration("cpa-unified-storage-v1"))
        XCTAssertEqual(try Data(contentsOf: oldURL), original)
        try database.execute("DROP TRIGGER fail_history")
        let restored = try await UsageLedger(url: oldURL, calendar: calendar).load()
        XCTAssertEqual(restored.totals.requests, 2)
        XCTAssertEqual(try database.scalarInt("SELECT COUNT(*) FROM cpa_events"), 1)
        XCTAssertTrue(try database.hasMigration("cpa-unified-storage-v1"))
    }

    func testBatchFailureRollsBackFactsSummaryAndWatermarkBeforeRetry() async throws {
        let root = try directory(), databaseURL = root.appendingPathComponent("analytics.sqlite")
        let ledger = UsageLedger(databaseURL: databaseURL, calendar: calendar)
        _ = try await ledger.load()
        let database = AnalyticsDatabase(url: databaseURL)
        try database.execute("""
            CREATE TRIGGER fail_bucket BEFORE INSERT ON cpa_daily_buckets
            BEGIN SELECT RAISE(ABORT,'fixture'); END
            """)
        let batch = [record(nil), record(nil), record("stable")]
        do {
            _ = try await ledger.ingest(batch, collectedAt: day)
            XCTFail("汇总失败不能留下已入库明细或推进采集水位")
        } catch {}
        XCTAssertEqual(try database.scalarInt("SELECT COUNT(*) FROM cpa_events"), 0)
        XCTAssertEqual(try database.scalarInt("SELECT COUNT(*) FROM cpa_daily_buckets"), 0)
        XCTAssertNil(try database.scalarInt("SELECT value FROM cpa_metadata WHERE key='last_collected'"))
        let unchanged = try await ledger.load()
        XCTAssertEqual(unchanged.totals.requests, 0); XCTAssertNil(unchanged.lastCollectedAt)
        try database.execute("DROP TRIGGER fail_bucket")
        let saved = try await ledger.ingest(batch, collectedAt: day)
        XCTAssertEqual(saved.totals.requests, 3, "无 ID 的相同并发请求仍是两次请求")
        let repeated = try await ledger.ingest([record("stable")], collectedAt: day)
        XCTAssertEqual(repeated.totals.requests, 3)
        XCTAssertEqual(try database.scalarInt("SELECT COUNT(*) FROM cpa_events"), 3)
    }

    func testLegacyMissingDayIsDeductedOnlyOnceAcrossOverlappingTimeZones() async throws {
        let root = try directory(), oldURL = root.appendingPathComponent("ledger.json")
        let utcDay = calendar.startOfDay(for: day)
        let localDay = utcDay.addingTimeInterval(-8 * 3600)
        var first = UsageBucket(day: utcDay, provider: "p", model: "m")
        first.requests = 100; first.totalTokens = 10_000
        var second = UsageBucket(day: localDay, provider: "p", model: "m")
        second.requests = 1; second.totalTokens = 120
        var snapshot = UsageLedgerSnapshot()
        snapshot.buckets = [first, second]; snapshot.lastCollectedAt = utcDay.addingTimeInterval(10 * 3600)
        try JSONEncoder().encode(snapshot).write(to: oldURL)
        let event = CPAUsageEvent(record: record("old-index", timestamp: utcDay.addingTimeInterval(2 * 3600)))
        try saveLegacyDatabase(events: [event], url: root.appendingPathComponent("usage-events.sqlite"), hasLedgerDay: false)
        var beijing = calendar; beijing.timeZone = TimeZone(secondsFromGMT: 8 * 3600)!
        for reader in [UsageLedger(url: oldURL, calendar: beijing), UsageLedger(url: oldURL, calendar: calendar)] {
            let report = try await reader.queryDashboard(CPAUsageQuery(), dimension: .model, metric: .tokens, limit: 8)
            let restored = try await reader.load()
            XCTAssertEqual(report.historicalRequests, 100)
            XCTAssertEqual(report.summary.metrics.requests, 101)
            XCTAssertEqual(report.summary.metrics.tokens, 10_120)
            XCTAssertEqual(restored.totals.requests, 101)
        }
    }
}
