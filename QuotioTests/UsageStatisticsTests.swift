import XCTest
@testable import Quotio

/// CPA 7 队列迁移回归：所有记录、目录和网络依赖均为构造数据，不读取用户凭据或真实会话。
final class UsageStatisticsTests: XCTestCase {
    private func temporaryURL() throws -> URL {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: directory) }
        return directory.appendingPathComponent("usage.json")
    }
    private func record(_ id: String, failed: Bool = false, total: Int = 30) -> UsageRecord {
        UsageRecord(timestamp: Date(timeIntervalSince1970: 1_700_000_000), provider: "test", model: "model-a",
                    requestID: id, failed: failed, latencyMilliseconds: 40,
                    tokens: .init(input: 10, output: 20, reasoning: 5, cached: 4, total: total))
    }

    func testCPASevenQueueDecodesAndNeverPersistsCredentials() throws {
        let data = Data(#"[{"timestamp":"2026-09-05T01:02:03.123456789Z","provider":"openai","model":"model-a","api_key":"private-fixture-key","source":"private-fixture-account","request_id":"req-a","tokens":{"input_tokens":100,"output_tokens":20,"cached_tokens":80,"reasoning_tokens":10,"total_tokens":120},"failed":false,"latency_ms":123}]"#.utf8)
        let batch = try JSONDecoder().decode(UsageQueueBatch.self, from: data)
        XCTAssertEqual(batch.records.count, 1)
        XCTAssertEqual(batch.records[0].tokens.total, 120)
        let serialized = String(decoding: try JSONEncoder().encode(batch.records), as: UTF8.self)
        XCTAssertFalse(serialized.contains("private-fixture"))
        XCTAssertFalse(serialized.contains("api_key"))
        XCTAssertEqual(try JSONDecoder().decode([UsageRecord].self, from: Data(serialized.utf8)), batch.records)
    }

    func testMalformedEntryDoesNotDropOtherAlreadyConsumedRecords() throws {
        let data = Data(#"[{"timestamp":"bad"},{"timestamp":"2026-09-05T01:02:03Z","tokens":{"total_tokens":7}},null]"#.utf8)
        let batch = try JSONDecoder().decode(UsageQueueBatch.self, from: data)
        XCTAssertEqual(batch.invalidCount, 2)
        XCTAssertEqual(batch.records.map(\.tokens.total), [7])
    }

    func testConcurrentIdenticalRecordsWithoutRequestIDAreNotCollapsed() async throws {
        let ledger = UsageLedger(url: try temporaryURL())
        let record = UsageRecord(timestamp: Date(timeIntervalSince1970: 1_700_000_000),
                                 provider: "same", model: "same", tokens: .init(total: 8))
        let result = try await ledger.ingest([record, record], collectedAt: Date())
        XCTAssertEqual(result.totals.requests, 2)
        XCTAssertEqual(result.totals.totalTokens, 16)
        XCTAssertTrue(result.recentRecordIDs.isEmpty)
    }

    func testTokenFallbackDoesNotDoubleCountCacheOrReasoning() throws {
        let data = Data(#"{"input_tokens":100,"output_tokens":20,"cached_tokens":80,"reasoning_tokens":10}"#.utf8)
        let tokens = try JSONDecoder().decode(UsageRecord.Tokens.self, from: data)
        XCTAssertEqual(tokens.total, 120)
        XCTAssertEqual(tokens.cached, 80)
    }

    func testExplicitZeroTokensStillCountsCompletedRequest() async throws {
        let ledger = UsageLedger(url: try temporaryURL())
        let result = try await ledger.ingest([record("zero", total: 0)], collectedAt: Date())
        XCTAssertEqual(result.totals.requests, 1)
        XCTAssertEqual(result.totals.totalTokens, 0)
        XCTAssertEqual(result.totals.successRate, 100)
    }

    func testRepeatedBatchAndReopenDoNotDoubleCountAndKeepHistory() async throws {
        let url = try temporaryURL()
        let ledger = UsageLedger(url: url)
        let records = [record("one"), record("two", failed: true)]
        _ = try await ledger.ingest(records, collectedAt: Date())
        _ = try await ledger.ingest(records, collectedAt: Date())
        let reopened = UsageLedger(url: url)
        let result = try await reopened.ingest([record("one"), record("three")], collectedAt: Date())
        XCTAssertEqual(result.totals.requests, 3)
        XCTAssertEqual(result.totals.totalTokens, 90)
        XCTAssertEqual(result.totals.failures, 1)
        XCTAssertEqual(result.totals.latencySamples, 3)
        XCTAssertEqual(result.totals.averageLatencyMilliseconds, 40)
        XCTAssertEqual(result.buckets.count, 1)
        // 新安装只创建统一 SQL；JSON 不再承担运行时账本写入。
        XCTAssertFalse(FileManager.default.fileExists(atPath: url.path))
        let databaseURL = AnalyticsDatabase.storeURL(forLegacyURL: url)
        let permissions = try FileManager.default.attributesOfItem(atPath: databaseURL.path)[.posixPermissions] as? NSNumber
        XCTAssertEqual(permissions?.intValue, 0o600)
    }

    func testDistinctProvidersAndModelsKeepSeparateBuckets() async throws {
        let ledger = UsageLedger(url: try temporaryURL())
        let other = UsageRecord(timestamp: record("a").timestamp, provider: "another", model: "model-a", tokens: .init(total: 2))
        let result = try await ledger.ingest([record("a"), other], collectedAt: Date())
        XCTAssertEqual(result.buckets.count, 2)
        XCTAssertEqual(result.totals.requests, 2)
        XCTAssertEqual(result.totals.totalTokens, 32)
    }

    func testEmptyQueueIsKnownZeroWithoutErasingExistingTotals() async throws {
        let ledger = UsageLedger(url: try temporaryURL())
        let first = try await ledger.ingest([], collectedAt: Date())
        XCTAssertNotNil(first.lastCollectedAt)
        XCTAssertEqual(first.totals.requests, 0)
        XCTAssertNil(first.totals.successRate)
        _ = try await ledger.ingest([record("one")], collectedAt: Date())
        let result = try await ledger.ingest([], collectedAt: Date())
        XCTAssertEqual(result.totals.requests, 1)
    }

    func testCorruptLedgerIsNotOverwrittenWithEmptyData() async throws {
        let url = try temporaryURL(); let original = Data("invalid-ledger".utf8)
        try original.write(to: url)
        let ledger = UsageLedger(url: url)
        do { _ = try await ledger.ingest([record("one")], collectedAt: Date()); XCTFail("损坏账本不能覆盖") }
        catch { }
        XCTAssertEqual(try Data(contentsOf: url), original)
    }

    func testSymlinkDestinationIsRefusedWithoutChangingTarget() async throws {
        let url = try temporaryURL(); let target = url.deletingLastPathComponent().appendingPathComponent("target")
        let original = Data("preserve".utf8); try original.write(to: target)
        try FileManager.default.createSymbolicLink(at: url, withDestinationURL: target)
        let ledger = UsageLedger(url: url)
        do { _ = try await ledger.ingest([record("one")], collectedAt: Date()); XCTFail("符号链接不应被写入") }
        catch { }
        XCTAssertEqual(try Data(contentsOf: target), original)
    }

    func testDailyAggregationUsesProvidedCalendarAcrossMidnight() async throws {
        var calendar = Calendar(identifier: .gregorian); calendar.timeZone = TimeZone(secondsFromGMT: 8 * 3600)!
        let ledger = UsageLedger(url: try temporaryURL(), calendar: calendar)
        let date = ISO8601DateFormatter().date(from: "2026-09-05T16:00:00Z")!
        let records = [UsageRecord(timestamp: date.addingTimeInterval(-1), provider: "p", model: "m"),
                       UsageRecord(timestamp: date, provider: "p", model: "m")]
        let result = try await ledger.ingest(records, collectedAt: date)
        XCTAssertEqual(result.buckets.count, 2)
        XCTAssertEqual(result.buckets.map(\.requests), [1, 1])
    }
}
