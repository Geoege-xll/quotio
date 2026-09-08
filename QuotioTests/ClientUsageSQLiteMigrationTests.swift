import XCTest
@testable import Quotio

/// 迁移回归只构造脱敏记录与临时目录，验证旧文件只读、关系型行存储和中断后的重放边界。
final class ClientUsageSQLiteMigrationTests: XCTestCase {
    private func temporary() throws -> URL {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: root) }
        return root
    }
    private func record(_ source: ClientUsageSource, identity: String = "legacy", output: Int = 20) -> ClientUsageRecord {
        ClientUsageRecord(identity: identity, source: source, timestamp: Date(timeIntervalSince1970: 1000),
                          model: "migration-model", input: 100, output: output, cached: 20)
    }

    func testLedgerMigrationIsOnceOnlyAndSubsequentWritesLeaveJSONUntouched() async throws {
        let root = try temporary(), legacyURL = root.appendingPathComponent("ledger.json")
        let databaseURL = root.appendingPathComponent("analytics.sqlite")
        let archived = ClientUsageSnapshot(records: [record(.claude)],
            statuses: [ClientUsageStatus(source: .claude, available: true, hasErrors: false, filesScanned: 1)],
            collectedAt: Date(timeIntervalSince1970: 2000))
        let original = try JSONEncoder().encode(archived)
        try original.write(to: legacyURL)
        let engine = ClientUsageEngine(url: legacyURL, databaseURL: databaseURL, homeDirectory: root.path, environment: [:])
        let imported = try await engine.load()
        XCTAssertEqual(imported.records, archived.records)
        let updated = try await engine.merge(scans: [ClientUsageScan(source: .claude,
            records: [record(.claude, output: 30)], available: true)], at: Date(timeIntervalSince1970: 3000))
        XCTAssertEqual(updated.records.first?.total, 130)
        XCTAssertEqual(try Data(contentsOf: legacyURL), original, "迁移后不再双写旧 JSON")

        // 迁移后旧备份即使被外部替换，也不能再次导入或阻挡数据库正常恢复。
        try Data("broken legacy backup".utf8).write(to: legacyURL)
        let reopened = try await ClientUsageEngine(url: legacyURL, databaseURL: databaseURL,
            homeDirectory: root.path, environment: [:]).load()
        XCTAssertEqual(reopened.records, updated.records)
        let database = AnalyticsDatabase(url: databaseURL)
        XCTAssertEqual(try database.scalarInt("SELECT count(*) FROM client_usage_records WHERE scope='ledger'"), 1)
        XCTAssertEqual(try database.scalarInt("SELECT total FROM client_usage_records WHERE scope='ledger'"), 130)
        XCTAssertTrue(try database.hasMigration("client-usage-ledger-v1"))
    }

    func testClaudeAndPiLegacyOrphanIndexesImportWithoutSourceLogs() throws {
        let root = try temporary()
        let directory = root.appendingPathComponent("old-cache")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let fingerprint = ClaudeClientUsageReader.Fingerprint(device: 1, inode: 2, size: 40,
            modifiedSeconds: 3, modifiedNanoseconds: 0, changedSeconds: 3, changedNanoseconds: 0,
            createdSeconds: 1, createdNanoseconds: 0)
        for source in [ClientUsageSource.claude, .pi] {
            let url = directory.appendingPathComponent(source.rawValue + ".json")
            let entry = ClaudeClientUsageReader.Entry(fingerprint: fingerprint, prefixDigest: String(repeating: "a", count: 64),
                boundaryDigest: String(repeating: "b", count: 64), offset: 40, records: [record(source)],
                hasErrors: false, tailHasErrors: false)
            var cache = ClaudeClientUsageReader.Cache()
            cache.files[String(repeating: "c", count: 64)] = entry
            let original = try JSONEncoder().encode(cache)
            try original.write(to: url)
            let scan = source == .claude
                ? try ClaudeClientUsageSource(homeDirectory: root.path, environment: [:]).collect(cacheURL: url)
                : try PiClientUsageSource(homeDirectory: root.path, environment: [:]).collect(cacheURL: url)
            XCTAssertFalse(scan.available)
            XCTAssertEqual(scan.records, entry.records, "源日志消失前已采集的用量不能在迁移中丢失")
            XCTAssertEqual(try Data(contentsOf: url), original)
            try FileManager.default.removeItem(at: url)
            let store = ClientUsageSQLiteStore(databaseURL: AnalyticsDatabase.storeURL(forLegacyURL: url))
            XCTAssertEqual(try store.loadLineCache(source: source, legacyURL: url), cache)
        }
    }

    func testCodexLegacyOrphanCheckpointsMigrateAndRemainQueryableAfterReopen() throws {
        let root = try temporary(), legacyURL = root.appendingPathComponent("codex.json")
        let directory = CodexUsageFileCache.directory(base: legacyURL)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let checkpoint = CodexUsageCheckpoint(rawSessionID: "private-old-session", rawParentSessionID: nil,
            timestamp: Date(timeIntervalSince1970: 1000), forkDate: nil, model: "model",
            cumulative: .init(input: 100, output: 20, cached: 5, reasoning: 0, total: 120), last: nil, ordinal: 0)
        let cache = CodexUsageFileCache(stamp: CodexUsageFileStamp(device: 1, inode: 2, size: 40,
            modifiedSeconds: 3, modifiedNanos: 0, changedSeconds: 3, changedNanos: 0), offset: 40,
            ordinal: 1, model: "model", hashedSessionID: checkpoint.sessionID, foundMetadata: true,
            hasErrors: false, prefixHash: String(repeating: "a", count: 64), boundaryHash: String(repeating: "b", count: 64),
            checkpoints: [checkpoint])
        let key = String(repeating: "c", count: 64) + ".json"
        let file = directory.appendingPathComponent(key)
        let original = try JSONEncoder().encode(cache)
        try original.write(to: file)
        let scan = try CodexClientUsageSource(homeDirectory: root.path, environment: [:]).collect(cacheURL: legacyURL)
        XCTAssertFalse(scan.available)
        XCTAssertEqual(scan.records.first?.total, 120)
        XCTAssertEqual(try Data(contentsOf: file), original)
        try FileManager.default.removeItem(at: directory)
        let reopened = try CodexClientUsageSource(homeDirectory: root.path, environment: [:]).collect(cacheURL: legacyURL)
        XCTAssertEqual(reopened.codexCheckpoints, [checkpoint])
        XCTAssertEqual(reopened.records, scan.records)
        let database = AnalyticsDatabase(url: AnalyticsDatabase.storeURL(forLegacyURL: legacyURL))
        XCTAssertEqual(try database.scalarInt("SELECT count(*) FROM client_usage_checkpoints WHERE scope LIKE 'scan:codex:%'"), 1)
    }

    func testOpenCodeLegacyCacheMigrationPreservesRevisionsAndHistoricalRecords() throws {
        let root = try temporary(), legacyURL = root.appendingPathComponent("opencode.json")
        let cache = OpenCodeClientUsageCache(databaseIdentity: String(repeating: "a", count: 64),
            fingerprint: String(repeating: "b", count: 64),
            revisions: [String(repeating: "c", count: 64): String(repeating: "d", count: 64)],
            records: [record(.opencode)], hasErrors: false)
        let original = try JSONEncoder().encode(cache)
        try original.write(to: legacyURL)
        let scan = try OpenCodeClientUsageSource(homeDirectory: root.path, environment: [:]).collect(cacheURL: legacyURL)
        XCTAssertEqual(scan.records, cache.records)
        XCTAssertFalse(scan.available)
        XCTAssertEqual(try Data(contentsOf: legacyURL), original)
        try FileManager.default.removeItem(at: legacyURL)
        let store = ClientUsageSQLiteStore(databaseURL: AnalyticsDatabase.storeURL(forLegacyURL: legacyURL))
        XCTAssertEqual(try store.loadOpenCodeCache(legacyURL: legacyURL), cache)
        XCTAssertEqual(try store.database.scalarInt("SELECT count(*) FROM client_usage_opencode_revisions"), 1)
    }

    func testUnchangedScanCacheDoesNotWriteRowsAndCheckpointUpdateRollsBackTogether() throws {
        let root = try temporary(), databaseURL = root.appendingPathComponent("analytics.sqlite")
        let store = ClientUsageSQLiteStore(databaseURL: databaseURL)
        _ = try store.loadLineCache(source: .claude, legacyURL: nil)
        var cache = ClaudeClientUsageReader.Cache()
        let key = String(repeating: "a", count: 64)
        cache.files[key] = ClaudeClientUsageReader.Entry(fingerprint: .init(device: 1, inode: 2, size: 100,
            modifiedSeconds: 1, modifiedNanoseconds: 0, changedSeconds: 1, changedNanoseconds: 0,
            createdSeconds: 1, createdNanoseconds: 0), prefixDigest: "prefix", boundaryDigest: "boundary",
            offset: 100, records: [record(.claude)], hasErrors: false, tailHasErrors: false)
        try store.saveLineCache(cache, source: .claude)
        let before = try store.database.scalarInt("SELECT total_changes()")
        try store.saveLineCache(cache, source: .claude)
        XCTAssertEqual(try store.database.scalarInt("SELECT total_changes()"), before, "无变化刷新不能再次写入全部索引")

        // 在水位写入时注入失败，验证此前写入的新记录也被同一事务回滚。
        try store.database.execute("""
            CREATE TRIGGER fail_test_cursor BEFORE INSERT ON client_usage_line_files
            BEGIN SELECT RAISE(ABORT, 'test cursor failure'); END
            """)
        cache.files[key]?.records.append(record(.claude, identity: "new-record"))
        XCTAssertThrowsError(try store.saveLineCache(cache, source: .claude))
        try store.database.execute("DROP TRIGGER fail_test_cursor")
        let restored = try ClientUsageSQLiteStore(databaseURL: databaseURL).loadLineCache(source: .claude, legacyURL: nil)
        XCTAssertEqual(restored.files[key]?.records.count, 1, "水位失败时不能留下半批解析记录")
        XCTAssertEqual(restored.files[key]?.offset, 100)
        try store.saveLineCache(cache, source: .claude)
        XCTAssertEqual(try ClientUsageSQLiteStore(databaseURL: databaseURL).loadLineCache(source: .claude, legacyURL: nil).files[key]?.records.count, 2)
    }

    func testInvalidLegacyLineEntryDoesNotMarkMigrationAndCanBeRepaired() throws {
        let root = try temporary(), legacyURL = root.appendingPathComponent("claude.json")
        let databaseURL = root.appendingPathComponent("analytics.sqlite")
        let fingerprint = ClaudeClientUsageReader.Fingerprint(device: 1, inode: 2, size: 40,
            modifiedSeconds: 3, modifiedNanoseconds: 0, changedSeconds: 3, changedNanoseconds: 0,
            createdSeconds: 1, createdNanoseconds: 0)
        let entry = ClaudeClientUsageReader.Entry(fingerprint: fingerprint, prefixDigest: "prefix", boundaryDigest: "boundary",
            offset: 40, records: [record(.claude)], hasErrors: false, tailHasErrors: false)
        var legacy = ClaudeClientUsageReader.Cache()
        legacy.files[String(repeating: "a", count: 64)] = entry
        var invalid = entry
        invalid.offset = 100 // 指针超出文件边界，不能仅过滤该行后宣告整份迁移成功。
        legacy.files[String(repeating: "b", count: 64)] = invalid
        try JSONEncoder().encode(legacy).write(to: legacyURL)
        let store = ClientUsageSQLiteStore(databaseURL: databaseURL)
        XCTAssertThrowsError(try store.loadLineCache(source: .claude, legacyURL: legacyURL))
        XCTAssertFalse(try store.database.hasMigration("client-usage-line-cache-v2-claude"))
        XCTAssertEqual(try store.database.scalarInt("SELECT count(*) FROM client_usage_line_files"), 0)
        legacy.files.removeValue(forKey: String(repeating: "b", count: 64))
        try JSONEncoder().encode(legacy).write(to: legacyURL)
        XCTAssertEqual(try store.loadLineCache(source: .claude, legacyURL: legacyURL), legacy)
        XCTAssertTrue(try store.database.hasMigration("client-usage-line-cache-v2-claude"))
    }

    func testCorruptCodexOrphanIndexRemainsRetryableUntilRepaired() throws {
        let root = try temporary(), legacyURL = root.appendingPathComponent("codex.json")
        let directory = CodexUsageFileCache.directory(base: legacyURL)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let file = directory.appendingPathComponent(String(repeating: "a", count: 64) + ".json")
        try Data("temporarily corrupt index".utf8).write(to: file)
        let store = ClientUsageSQLiteStore(databaseURL: root.appendingPathComponent("analytics.sqlite"))
        XCTAssertThrowsError(try store.loadCodexCaches(legacyURL: legacyURL))
        XCTAssertFalse(try store.database.hasMigration("client-usage-codex-cache-v2"))
        let checkpoint = CodexUsageCheckpoint(rawSessionID: "orphan-session", rawParentSessionID: nil,
            timestamp: Date(timeIntervalSince1970: 1000), forkDate: nil, model: "model",
            cumulative: .init(input: 100, output: 0, cached: 0, reasoning: 0, total: 100), last: nil, ordinal: 0)
        let cache = CodexUsageFileCache(stamp: .init(device: 1, inode: 2, size: 40, modifiedSeconds: 3,
            modifiedNanos: 0, changedSeconds: 3, changedNanos: 0), offset: 40, ordinal: 1, model: "model",
            hashedSessionID: checkpoint.sessionID, foundMetadata: true, hasErrors: false,
            prefixHash: "prefix", boundaryHash: "boundary", checkpoints: [checkpoint])
        try JSONEncoder().encode(cache).write(to: file)
        XCTAssertEqual(try store.loadCodexCaches(legacyURL: legacyURL)[file.lastPathComponent], cache)
        XCTAssertTrue(try store.database.hasMigration("client-usage-codex-cache-v2"))
    }

    func testCorruptOpenCodeIndexDoesNotPermanentlyDiscardRecoverableHistory() throws {
        let root = try temporary(), legacyURL = root.appendingPathComponent("opencode.json")
        try Data("broken".utf8).write(to: legacyURL)
        let store = ClientUsageSQLiteStore(databaseURL: root.appendingPathComponent("analytics.sqlite"))
        XCTAssertThrowsError(try store.loadOpenCodeCache(legacyURL: legacyURL))
        XCTAssertFalse(try store.database.hasMigration("client-usage-opencode-cache-v1"))
        let cache = OpenCodeClientUsageCache(databaseIdentity: String(repeating: "a", count: 64),
            fingerprint: String(repeating: "b", count: 64), revisions: [:], records: [record(.opencode)], hasErrors: false)
        try JSONEncoder().encode(cache).write(to: legacyURL)
        XCTAssertEqual(try store.loadOpenCodeCache(legacyURL: legacyURL), cache)
        XCTAssertTrue(try store.database.hasMigration("client-usage-opencode-cache-v1"))
    }

    func testPresentationRebucketsUnchangedSnapshotWhenCalendarTimeZoneChanges() async throws {
        let root = try temporary()
        let engine = ClientUsageEngine(databaseURL: root.appendingPathComponent("analytics.sqlite"),
                                       homeDirectory: root.path, environment: [:])
        var utc = Calendar(identifier: .gregorian)
        utc.timeZone = TimeZone(secondsFromGMT: 0)!
        var beijing = utc
        beijing.timeZone = TimeZone(secondsFromGMT: 8 * 3600)!
        let timestamp = utc.date(from: DateComponents(year: 2026, month: 9, day: 5, hour: 22))!
        let event = ClientUsageRecord(identity: "cross-midnight", source: .claude, timestamp: timestamp,
                                      model: "model", input: 100, output: 20)
        _ = try await engine.merge(scans: [ClientUsageScan(source: .claude, records: [event], available: true)], at: timestamp)
        let first = try await engine.loadPresentation(calendar: utc)
        let changed = try await engine.loadPresentation(calendar: beijing)
        XCTAssertTrue(first.snapshot.records.isEmpty, "展示快照不携带完整历史事件")
        XCTAssertTrue(changed.snapshot.records.isEmpty, "改变日历后仍只返回统计汇总")
        XCTAssertNil(changed.snapshot.codexCheckpoints, "展示层不能保留重算检查点")
        let preserved = try await engine.load()
        XCTAssertEqual(preserved.records, [event], "改变日历不能修改或丢失数据库事实")
        XCTAssertEqual(first.buckets.first?.day, utc.startOfDay(for: timestamp))
        XCTAssertEqual(changed.buckets.first?.day, beijing.startOfDay(for: timestamp))
        XCTAssertNotEqual(first.buckets.first?.day, changed.buckets.first?.day)
        XCTAssertEqual(changed.buckets.first?.totalTokens, 120)
        let returned = try await engine.loadPresentation(calendar: utc)
        XCTAssertEqual(returned.buckets, first.buckets)
    }
}
