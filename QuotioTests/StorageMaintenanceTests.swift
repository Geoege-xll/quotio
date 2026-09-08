import XCTest
@testable import Quotio

/// 所有清理测试只使用临时数据库；不启动真实客户端扫描、不清理用户缓存或生产统计。
@MainActor
final class StorageMaintenanceTests: XCTestCase {
    private enum TestError: Error { case preparation, invalidation }

    private func location() throws -> URL {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("storage-maintenance-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: root) }
        return root.appendingPathComponent("analytics.sqlite")
    }

    /// 最小列集合与生产统计表对应，额外汇总表用于验证未来 client_usage_ 表仍被同模块清理覆盖。
    private func seededDatabase(_ url: URL) throws -> AnalyticsDatabase {
        let database = AnalyticsDatabase(url: url)
        for table in ["cpa_events", "cpa_daily_buckets", "cpa_historical_buckets", "cpa_legacy_dedup_ids", "cpa_metadata",
                      "cpa_model_prices", "call_daily", "call_agent_daily", "call_inventory", "call_source_status", "call_scan_checkpoint",
                      "client_usage_checkpoints", "client_usage_status", "client_usage_metadata", "client_usage_line_files",
                      "client_usage_codex_files", "client_usage_opencode_state", "client_usage_opencode_revisions", "client_usage_future_summary",
                      "unrelated_configuration"] {
            try database.execute("CREATE TABLE \(table)(id INTEGER PRIMARY KEY)")
            try database.execute("INSERT INTO \(table) VALUES(1)")
        }
        try database.execute("CREATE TABLE client_usage_records(scope TEXT, id INTEGER)")
        try database.execute("INSERT INTO client_usage_records VALUES('ledger',1),('scan:missing-source',1)")
        try database.execute("CREATE TABLE call_meta(id INTEGER PRIMARY KEY, generated_at REAL, schema_version INTEGER, aggregation_timezone TEXT)")
        try database.execute("INSERT INTO call_meta VALUES(1,100,7,'Asia/Shanghai')")
        return database
    }

    func testInspectWithoutDatabaseDoesNotCreateStorage() async throws {
        let url = try location()
        let snapshot = try await StorageMaintenanceStore(databaseURL: url).inspect()
        XCTAssertEqual(snapshot.totalBytes, 0)
        XCTAssertTrue(snapshot.recordCounts.isEmpty)
        XCTAssertFalse(FileManager.default.fileExists(atPath: url.path))
    }

    func testInspectCountsLedgerWithoutDoubleCountingScanInputs() async throws {
        let url = try location()
        let database = try seededDatabase(url)
        let snapshot = try await StorageMaintenanceStore(databaseURL: url).inspect()
        XCTAssertEqual(snapshot.recordCounts[.dashboard], 2)
        XCTAssertEqual(snapshot.recordCounts[.clientUsage], 1)
        XCTAssertEqual(snapshot.recordCounts[.callAnalytics], 2)
        XCTAssertGreaterThan(snapshot.totalBytes, 0)
        XCTAssertEqual(try database.scalarInt("SELECT COUNT(*) FROM client_usage_records"), 2)
    }

    func testClearClientModuleIncludesScanFactsButPreservesOtherModulesAndConfiguration() async throws {
        let url = try location()
        let database = try seededDatabase(url)
        let result = try await StorageMaintenanceStore(databaseURL: url).clearStatistics([.clientUsage])
        XCTAssertGreaterThan(result.deletedCounts[.clientUsage] ?? 0, 2)
        XCTAssertNil(result.deletedCounts[.dashboard])
        for table in ["client_usage_records", "client_usage_checkpoints", "client_usage_codex_files", "client_usage_future_summary"] {
            XCTAssertEqual(try database.scalarInt("SELECT COUNT(*) FROM \(table)"), 0)
        }
        for table in ["cpa_events", "call_daily", "cpa_model_prices", "unrelated_configuration"] {
            XCTAssertEqual(try database.scalarInt("SELECT COUNT(*) FROM \(table)"), 1)
        }
        for migration in ["client-usage-ledger-v1", "client-usage-line-cache-v2-claude", "client-usage-line-cache-v2-pi",
                          "client-usage-codex-cache-v2", "client-usage-opencode-cache-v1"] {
            XCTAssertTrue(try database.hasMigration(migration))
        }
        XCTAssertFalse(try database.hasMigration("cpa-unified-storage-v1"))
    }

    func testClearDashboardPreservesPricesAndExistingMigrationMarkers() async throws {
        let url = try location()
        let database = try seededDatabase(url)
        try database.markMigration("unrelated-migration")
        let result = try await StorageMaintenanceStore(databaseURL: url).clearStatistics([.dashboard])
        XCTAssertEqual(result.deletedCounts[.dashboard], 5)
        XCTAssertEqual(try database.scalarInt("SELECT COUNT(*) FROM cpa_model_prices"), 1)
        XCTAssertEqual(try database.scalarInt("SELECT COUNT(*) FROM cpa_events"), 0)
        XCTAssertTrue(try database.hasMigration("cpa-unified-storage-v1"))
        XCTAssertTrue(try database.hasMigration("unrelated-migration"))
    }

    func testClearCallsKeepsArchiveTimeZoneAndResetsCollectionDate() async throws {
        let url = try location()
        let database = try seededDatabase(url)
        _ = try await StorageMaintenanceStore(databaseURL: url).clearStatistics([.callAnalytics])
        XCTAssertEqual(try database.scalarInt("SELECT COUNT(*) FROM call_daily"), 0)
        XCTAssertEqual(try database.scalarText("SELECT aggregation_timezone FROM call_meta"), "Asia/Shanghai")
        XCTAssertEqual(try database.scalarInt("SELECT schema_version FROM call_meta"), 7)
        XCTAssertLessThan(try XCTUnwrap(database.scalarInt("SELECT CAST(generated_at AS INTEGER) FROM call_meta")), 0)
        XCTAssertTrue(try database.hasMigration("call_analytics_json_v1"))
    }

    func testClearUninitializedModuleCreatesMigrationTombstonesWithoutOldImport() async throws {
        let url = try location()
        let result = try await StorageMaintenanceStore(databaseURL: url).clearStatistics([.clientUsage, .dashboard, .callAnalytics])
        let database = AnalyticsDatabase(url: url)
        XCTAssertEqual(result.totalDeletedCount, 0)
        XCTAssertTrue(try database.hasMigration("client-usage-ledger-v1"))
        XCTAssertTrue(try database.hasMigration("cpa-unified-storage-v1"))
        XCTAssertTrue(try database.hasMigration("call_analytics_json_v1"))
    }

    func testFailureRollsBackEverySelectedModuleAndMigrationMarker() async throws {
        let url = try location()
        let database = try seededDatabase(url)
        try database.execute("CREATE TRIGGER reject_cleanup BEFORE DELETE ON client_usage_records BEGIN SELECT RAISE(ABORT,'fixture failure'); END")
        do {
            _ = try await StorageMaintenanceStore(databaseURL: url).clearStatistics([.dashboard, .clientUsage])
            XCTFail("被拒绝的删除应抛出错误")
        } catch { }
        XCTAssertEqual(try database.scalarInt("SELECT COUNT(*) FROM cpa_events"), 1)
        XCTAssertEqual(try database.scalarInt("SELECT COUNT(*) FROM client_usage_records"), 2)
        XCTAssertEqual(try database.scalarInt("SELECT COUNT(*) FROM client_usage_checkpoints"), 1)
        XCTAssertFalse(try database.hasMigration("cpa-unified-storage-v1"))
        XCTAssertFalse(try database.hasMigration("client-usage-ledger-v1"))
    }

    func testClientPrefixCannotTurnDatabaseIdentifierIntoSQL() async throws {
        let url = try location()
        let database = try seededDatabase(url)
        try database.execute("CREATE TABLE \"client_usage_x; DROP TABLE cpa_events\"(id INTEGER)")
        try database.execute("INSERT INTO \"client_usage_x; DROP TABLE cpa_events\" VALUES(1)")
        _ = try await StorageMaintenanceStore(databaseURL: url).clearStatistics([.clientUsage])
        XCTAssertEqual(try database.scalarInt("SELECT COUNT(*) FROM cpa_events"), 1)
        XCTAssertEqual(try database.scalarInt("SELECT COUNT(*) FROM \"client_usage_x; DROP TABLE cpa_events\""), 1)
    }

    func testCompactionReclaimsFreePagesAndPreservesStatistics() async throws {
        let url = try location()
        let database = try seededDatabase(url)
        try database.execute("CREATE TABLE temporary_payload(id INTEGER PRIMARY KEY, payload BLOB)")
        try database.transaction {
            for index in 0..<64 {
                try database.execute("INSERT INTO temporary_payload VALUES(?,?)", [.integer(Int64(index)), .blob(Data(repeating: 1, count: 16_384))])
            }
        }
        let before = try XCTUnwrap(database.scalarInt("PRAGMA page_count"))
        try database.execute("DELETE FROM temporary_payload")
        let snapshot = try await StorageMaintenanceStore(databaseURL: url).compact()
        XCTAssertLessThan(try XCTUnwrap(database.scalarInt("PRAGMA page_count")), before)
        XCTAssertEqual(snapshot.recordCounts[.clientUsage], 1)
        XCTAssertEqual(try database.scalarInt("SELECT COUNT(*) FROM cpa_model_prices"), 1)
    }

    func testServiceWaitsForPrepareThenInvalidatesAfterCommitAndResumes() async throws {
        let url = try location()
        let database = try seededDatabase(url)
        var events: [String] = []
        let service = StorageMaintenanceService(store: StorageMaintenanceStore(databaseURL: url), prepare: {
            events.append("prepare")
            // 模拟维护屏障等待最后一笔在途写入完成；该行必须包含在本次清理中。
            try database.execute("INSERT INTO cpa_events VALUES(2)")
        }, invalidate: { modules in
            XCTAssertEqual(modules, [.dashboard])
            XCTAssertEqual(try database.scalarInt("SELECT COUNT(*) FROM cpa_events"), 0)
            events.append("invalidate")
        }, resume: { events.append("resume") }, clearCaches: { XCTFail("清统计不能调用缓存路径") })
        await service.clearStatistics([.dashboard])
        XCTAssertEqual(events, ["prepare", "invalidate", "resume"])
        XCTAssertEqual(service.messageKey, "storage.data.cleared")
        XCTAssertNil(service.errorKey)
        XCTAssertFalse(service.isBusy)
        XCTAssertEqual(service.lastClearResult?.deletedCounts[.dashboard], 6)
    }

    func testPreparationFailureResumesWithoutDeletingAnything() async throws {
        let url = try location()
        let database = try seededDatabase(url)
        var resumed = false
        let service = StorageMaintenanceService(store: StorageMaintenanceStore(databaseURL: url), prepare: {
            throw TestError.preparation
        }, invalidate: { _ in XCTFail("准备失败不能失效数据") }, resume: { resumed = true }, clearCaches: { })
        await service.clearStatistics([.dashboard])
        XCTAssertTrue(resumed)
        XCTAssertEqual(service.errorKey, "storage.data.failed")
        XCTAssertEqual(try database.scalarInt("SELECT COUNT(*) FROM cpa_events"), 1)
        XCTAssertFalse(service.isBusy)
    }

    func testPostCommitInvalidationFailureClearlyReportsThatDataWasCleared() async throws {
        let url = try location()
        let database = try seededDatabase(url)
        var resumed = false
        let service = StorageMaintenanceService(store: StorageMaintenanceStore(databaseURL: url), prepare: { },
            invalidate: { _ in throw TestError.invalidation }, resume: { resumed = true }, clearCaches: { })
        await service.clearStatistics([.dashboard])
        XCTAssertTrue(resumed)
        XCTAssertEqual(service.errorKey, "storage.data.clearedRefreshFailed")
        XCTAssertNil(service.messageKey)
        XCTAssertEqual(try database.scalarInt("SELECT COUNT(*) FROM cpa_events"), 0)
        XCTAssertNotNil(service.lastClearResult)
    }

    func testCacheCleanupRetainsScanOnlyHistoryAndPreventsOverlappingDataDeletion() async throws {
        let url = try location()
        let database = try seededDatabase(url)
        var continuation: CheckedContinuation<Void, Never>?
        var cacheCleared = false
        var resumed = 0
        let service = StorageMaintenanceService(store: StorageMaintenanceStore(databaseURL: url), prepare: {
            await withCheckedContinuation { continuation = $0 }
        }, invalidate: { _ in XCTFail("缓存路径不清除统计") }, resume: { resumed += 1 }, clearCaches: { cacheCleared = true })
        let first = Task { await service.clearCaches() }
        while continuation == nil { await Task.yield() }
        XCTAssertTrue(service.isBusy)
        await service.clearStatistics([.clientUsage])
        continuation?.resume()
        await first.value
        XCTAssertTrue(cacheCleared)
        XCTAssertEqual(resumed, 1)
        XCTAssertEqual(try database.scalarInt("SELECT COUNT(*) FROM client_usage_records WHERE scope='scan:missing-source'"), 1)
        XCTAssertEqual(try database.scalarInt("SELECT COUNT(*) FROM client_usage_checkpoints"), 1)
        XCTAssertEqual(service.messageKey, "storage.cache.cleared")
    }
}
