import XCTest
@testable import Quotio

/// 只使用临时数据库和合成用量验证生产内存边界；测试不扫描真实客户端目录。
final class ClientUsageIncrementalStorageTests: XCTestCase {
    private func store() throws -> ClientUsageSQLiteStore {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: root) }
        let store = ClientUsageSQLiteStore(databaseURL: root.appendingPathComponent("analytics.sqlite"))
        _ = try store.loadLedgerMetadata(legacyURL: root.appendingPathComponent("absent-legacy.json"))
        return store
    }

    private var utc: Calendar {
        var value = Calendar(identifier: .gregorian)
        value.timeZone = TimeZone(secondsFromGMT: 0)!
        return value
    }

    private func checkpoint(_ session: String, parent: String? = nil, timestamp: Double,
                            fork: Double? = nil, total: Int, ordinal: Int = 0) -> CodexUsageCheckpoint {
        CodexUsageCheckpoint(rawSessionID: session, rawParentSessionID: parent,
            timestamp: Date(timeIntervalSince1970: timestamp), forkDate: fork.map(Date.init(timeIntervalSince1970:)),
            model: "test-model", cumulative: .init(input: total, output: 0, cached: 0, reasoning: 0, total: total),
            last: nil, ordinal: ordinal)
    }

    func testDisplayContainsOnlySmallSummariesAndUnchangedReadsDoNotWrite() throws {
        let store = try store()
        let records = (0..<2_000).map { index in
            ClientUsageRecord(identity: "event-\(index)", source: .claude,
                timestamp: Date(timeIntervalSince1970: 1_700_000_000 + Double(index)),
                model: "model-\(index % 2)", input: 100, output: 20)
        }
        try store.mergeIncrementally(scans: [ClientUsageScan(source: .claude, records: records, available: true)], at: Date())
        let display = try store.loadDisplay(calendar: utc)
        XCTAssertTrue(display.metadata.records.isEmpty, "生产展示不能继续传递全部历史记录")
        XCTAssertNil(display.metadata.codexCheckpoints)
        XCTAssertEqual(display.buckets.count, 2)
        XCTAssertEqual(display.buckets.reduce(0) { $0 + $1.requests }, 2_000)
        XCTAssertEqual(display.buckets.reduce(0) { $0 + $1.totalTokens }, 240_000)
        let changes = try store.database.scalarInt("SELECT total_changes()")
        let repeated = try store.loadDisplay(calendar: utc)
        XCTAssertEqual(repeated.buckets, display.buckets)
        XCTAssertEqual(try store.database.scalarInt("SELECT total_changes()"), changes,
                       "无变化切页只读汇总表，不能重算后再写回历史")
    }

    func testLateParentReprojectsOnlyAffectedSessionsAndCanDecreaseChildUsage() throws {
        let store = try store()
        let child = checkpoint("child", parent: "parent", timestamp: 1_600, fork: 1_500, total: 150)
        let unrelated = checkpoint("unrelated", timestamp: 500, total: 10)
        try store.mergeIncrementally(scans: [ClientUsageScan(source: .codex,
            codexCheckpoints: [child, unrelated], available: true)], at: Date())
        XCTAssertNil(try store.database.scalarInt("SELECT total FROM client_usage_records WHERE scope='ledger' AND id=?", [.text(child.id)]))
        XCTAssertEqual(try store.database.scalarInt("SELECT has_errors FROM client_usage_status WHERE source='codex'"), 1)
        let unrelatedRow = try store.database.scalarInt("SELECT rowid FROM client_usage_projection_status WHERE session_id=?", [.text(unrelated.sessionID)])

        let parent = checkpoint("parent", timestamp: 1_000, total: 100)
        try store.mergeIncrementally(scans: [ClientUsageScan(source: .codex,
            codexCheckpoints: [parent], available: true)], at: Date())
        XCTAssertEqual(try store.database.scalarInt("SELECT total FROM client_usage_records WHERE scope='ledger' AND id=?", [.text(child.id)]), 50)
        let before = try store.loadDisplay(calendar: utc)

        let predecessor = checkpoint("parent", timestamp: 1_200, total: 120, ordinal: 1)
        try store.mergeIncrementally(scans: [ClientUsageScan(source: .codex,
            codexCheckpoints: [predecessor], available: true)], at: Date())
        XCTAssertEqual(try store.database.scalarInt("SELECT total FROM client_usage_records WHERE scope='ledger' AND id=?", [.text(child.id)]), 30,
                       "迟到的父前驱补足继承量后，子会话已展示差额必须允许下降")
        XCTAssertEqual(try store.database.scalarInt("SELECT has_errors FROM client_usage_status WHERE source='codex'"), 0)
        XCTAssertEqual(try store.database.scalarInt("SELECT rowid FROM client_usage_projection_status WHERE session_id=?", [.text(unrelated.sessionID)]), unrelatedRow,
                       "另一个未变化会话不能被全历史重投影波及")
        XCTAssertEqual(try store.database.scalarInt("SELECT count(*) FROM client_usage_projection_dirty"), 0)
        let after = try store.loadDisplay(calendar: utc)
        XCTAssertEqual(after.buckets.reduce(0) { $0 + $1.totalTokens }, 160)
        XCTAssertEqual(after.buckets.reduce(0) { $0 + $1.totalTokens }, before.buckets.reduce(0) { $0 + $1.totalTokens })
    }

    func testDurablePendingScopeSurvivesFailedTransferAndCanReplayWithoutSourceFile() throws {
        let store = try store()
        let checkpoint = checkpoint("orphan", timestamp: 1_000, total: 120)
        let scope = "scan:codex:" + String(repeating: "a", count: 64)
        try store.database.transaction {
            try store.writeCheckpoints([checkpoint], previous: [], scope: scope)
            try store.markScanScopeDirty(scope)
        }
        try store.database.execute("""
            CREATE TRIGGER fail_test_ledger BEFORE INSERT ON client_usage_checkpoints
            WHEN NEW.scope='ledger' BEGIN SELECT RAISE(ABORT, 'synthetic transfer failure'); END
            """)
        XCTAssertThrowsError(try store.mergeIncrementally(scans: [ClientUsageScan(source: .codex)], at: Date()))
        XCTAssertEqual(try store.database.scalarInt("SELECT count(*) FROM client_usage_dirty_scopes"), 1)
        XCTAssertEqual(try store.database.scalarInt("SELECT count(*) FROM client_usage_checkpoints WHERE scope='ledger'"), 0)
        try store.database.execute("DROP TRIGGER fail_test_ledger")
        // 不创建任何源日志；下一轮仅凭磁盘待办就能恢复此前已经采集的用量。
        try store.mergeIncrementally(scans: [ClientUsageScan(source: .codex)], at: Date())
        XCTAssertEqual(try store.database.scalarInt("SELECT count(*) FROM client_usage_dirty_scopes"), 0)
        XCTAssertEqual(try store.database.scalarInt("SELECT total FROM client_usage_records WHERE scope='ledger'"), 120)
    }

    func testDuplicateCheckpointDoesNotReprojectAndPiUnknownReasoningCanBeRepaired() throws {
        let store = try store()
        let checkpoint = checkpoint("stable", timestamp: 1_000, total: 120)
        let scan = ClientUsageScan(source: .codex, codexCheckpoints: [checkpoint], available: true)
        try store.mergeIncrementally(scans: [scan], at: Date())
        let row = try store.database.scalarInt("SELECT rowid FROM client_usage_projection_status WHERE session_id=?", [.text(checkpoint.sessionID)])
        try store.mergeIncrementally(scans: [scan], at: Date())
        XCTAssertEqual(try store.database.scalarInt("SELECT rowid FROM client_usage_projection_status WHERE session_id=?", [.text(checkpoint.sessionID)]), row)

        func pi(_ known: Bool?) -> ClientUsageRecord {
            ClientUsageRecord(identity: "pi-entry", source: .pi, timestamp: Date(timeIntervalSince1970: 2_000),
                              model: "pi-model", input: 10, output: 5, hasReasoningBreakdown: known)
        }
        try store.mergeIncrementally(scans: [ClientUsageScan(source: .pi, records: [pi(nil)], available: true)], at: Date())
        XCTAssertEqual(try store.loadDisplay(calendar: utc).reasoningUnknownDays.count, 1, "旧归档缺失字段也属于未知")
        try store.mergeIncrementally(scans: [ClientUsageScan(source: .pi, records: [pi(true)], available: true)], at: Date())
        XCTAssertTrue(try store.loadDisplay(calendar: utc).reasoningUnknownDays.isEmpty)
        try store.mergeIncrementally(scans: [ClientUsageScan(source: .pi, records: [pi(false)], available: true)], at: Date())
        XCTAssertEqual(try store.loadDisplay(calendar: utc).reasoningUnknownDays.count, 1)
        try store.mergeIncrementally(scans: [ClientUsageScan(source: .pi, records: [pi(true)], available: true)], at: Date())
        XCTAssertTrue(try store.loadDisplay(calendar: utc).reasoningUnknownDays.isEmpty)
    }

    func testCalendarRebuildHonorsDaylightSavingAndKeepsFactsOnDisk() throws {
        let store = try store()
        var pacific = utc
        pacific.timeZone = TimeZone(identifier: "America/Los_Angeles")!
        let first = utc.date(from: DateComponents(year: 2026, month: 3, day: 8, hour: 9))!
        let second = utc.date(from: DateComponents(year: 2026, month: 3, day: 9, hour: 7))!
        let records = [first, second].enumerated().map { index, date in
            ClientUsageRecord(identity: "dst-\(index)", source: .claude, timestamp: date, model: "model", input: 100, output: 0)
        }
        try store.mergeIncrementally(scans: [ClientUsageScan(source: .claude, records: records, available: true)], at: second)
        let result = try store.loadDisplay(calendar: pacific)
        XCTAssertEqual(result.buckets.map(\.day), [pacific.startOfDay(for: first), pacific.startOfDay(for: second)])
        XCTAssertEqual(result.buckets[1].day.timeIntervalSince(result.buckets[0].day), 23 * 3_600)
        XCTAssertTrue(result.metadata.records.isEmpty)
        let otherCalendar = try store.loadDisplay(calendar: utc)
        XCTAssertEqual(otherCalendar.buckets.reduce(0) { $0 + $1.totalTokens }, 200)
        XCTAssertEqual(try store.database.scalarInt("SELECT count(*) FROM client_usage_records WHERE scope='ledger'"), 2)
    }

    func testMultipleCheckpointCorrectionsCanQueueOneSessionWithoutConstraintFailure() throws {
        let store = try store()
        var first = checkpoint("corrected-session", timestamp: 1_000, total: 100)
        var second = checkpoint("corrected-session", timestamp: 2_000, total: 120, ordinal: 1)
        first.model = "unknown"; second.model = "unknown"
        try store.mergeIncrementally(scans: [ClientUsageScan(source: .codex,
            codexCheckpoints: [first, second], available: true)], at: Date())
        _ = try store.loadDisplay(calendar: utc)
        first.model = "known-model"; second.model = "known-model"
        // 两个已存在检查点在同一事务补全模型，会重复触发同一待投影会话标记。
        // 验证触发器去重不被外层 UPSERT 的冲突策略覆盖，并清除旧模型的日汇总。
        try store.mergeIncrementally(scans: [ClientUsageScan(source: .codex,
            codexCheckpoints: [first, second], available: true)], at: Date())
        let result = try store.loadDisplay(calendar: utc)
        XCTAssertEqual(result.buckets.count, 1)
        XCTAssertEqual(result.buckets.first?.model, "known-model")
        XCTAssertEqual(result.buckets.first?.totalTokens, 120)
        XCTAssertEqual(try store.database.scalarInt("SELECT count(*) FROM client_usage_projection_dirty"), 0)
    }
}
