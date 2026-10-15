import Foundation
import SQLite3

nonisolated struct QuotaHistorySample: Sendable {
    let account: QuotaHistoryAccount
    let point: QuotaHistoryPoint
}

nonisolated enum QuotaHistoryError: Error { case busy, invalidPayload }

/// 账号额度历史独占一个 SQLite 连接，复用现有统计数据库文件和安全路径规则。
/// 每分钟每指标至多保留一个最新真实观测，最多三十天／十万条；不保存任何凭据或请求正文。
/// 方法内部没有网络等待，写入与清理均在同步事务内完成，世代拒绝排队的旧写入。
actor QuotaHistoryStore {
    private let database: AnalyticsDatabase
    private var isPrepared = false
    private var generation: UInt64 = 0
    static let retention: TimeInterval = 30 * 86_400
    static let maximumSamples = 100_000

    init(databaseURL: URL = AnalyticsDatabase.defaultURL()) {
        database = AnalyticsDatabase(url: databaseURL)
    }

    /// 暂停／清理先推进世代；旧任务即使之后才排到 actor，也不能恢复已删除历史。
    func advanceGeneration(to value: UInt64) { generation = max(generation, value) }

    func record(_ samples: [QuotaHistorySample], generation expected: UInt64, now: Date = Date()) throws -> Bool {
        guard expected == generation, !samples.isEmpty else { return false }
        try prepare()
        return try database.transaction {
            var changed = false
            let allCleared = try clearedAfter(key: "cleared.all")
            var clearedAccounts: [QuotaHistoryAccount: TimeInterval] = [:]
            for sample in samples {
                try Task.checkCancellation()
                let date = sample.point.date.timeIntervalSince1970
                guard date.isFinite, sample.point.value.isFinite, sample.point.value >= 0,
                      date >= now.addingTimeInterval(-Self.retention).timeIntervalSince1970,
                      date <= now.addingTimeInterval(60).timeIntervalSince1970,
                      let minute = Int64(exactly: floor(date / 60)) else { continue }
                let accountCleared: TimeInterval
                if let known = clearedAccounts[sample.account] { accountCleared = known }
                else {
                    accountCleared = try clearedAfter(key: Self.clearKey(sample.account))
                    clearedAccounts[sample.account] = accountCleared
                }
                guard date > max(allCleared, accountCleared) else { continue }
                let point = sample.point, account = sample.account
                let payload = try JSONEncoder().encode(point)
                // 同一缓存快照的重复发布不会形成新观测；同一分钟也只能由更新的源时间替换。
                try database.execute("""
                    INSERT INTO quota_history_samples
                    (mode,provider,account_key,metric_id,bucket,observed_at,payload) VALUES(?,?,?,?,?,?,?)
                    ON CONFLICT(mode,provider,account_key,metric_id,bucket) DO UPDATE SET
                    observed_at=excluded.observed_at,payload=excluded.payload
                    WHERE excluded.observed_at > quota_history_samples.observed_at
                    """, [.text(account.mode), .text(account.provider.rawValue), .text(account.accountKey),
                          .text(point.metricID), .integer(minute), .real(date), .blob(payload)])
                changed = changed || database.changes > 0
            }
            try prune(now: now)
            return changed
        }
    }

    /// 指标目录有界读取每项最新元数据；只用于同一精确账号的下拉选择。
    func metrics(account: QuotaHistoryAccount, now: Date = Date()) throws -> [QuotaHistoryPoint] {
        guard FileManager.default.fileExists(atPath: database.url.path) else { return [] }
        try prepare()
        return try database.query("""
            SELECT payload FROM (
              SELECT payload,observed_at,ROW_NUMBER() OVER(PARTITION BY metric_id ORDER BY observed_at DESC) AS position
              FROM quota_history_samples WHERE mode=? AND provider=? AND account_key=? AND observed_at>=? AND observed_at<=?
            ) WHERE position=1 ORDER BY observed_at DESC LIMIT 128
            """, accountValues(account) + [.real(now.addingTimeInterval(-Self.retention).timeIntervalSince1970),
                                          .real(now.timeIntervalSince1970)], map: decode)
    }

    /// 每次图表至多返回 720 个实际观测桶；原始分钟点只在历史 actor 内处理，不搬到主线程。
    /// 先识别充值、重置、离线间隔，再抽样，避免桶内发生的断点在抽样后丢失。
    func points(account: QuotaHistoryAccount, metricID: String, range: QuotaHistoryRange,
                now: Date = Date()) throws -> [QuotaHistoryChartPoint] {
        guard FileManager.default.fileExists(atPath: database.url.path) else { return [] }
        try prepare()
        let from = now.addingTimeInterval(-range.seconds).timeIntervalSince1970
        let samples = try database.query("""
            SELECT payload FROM quota_history_samples
            WHERE mode=? AND provider=? AND account_key=? AND metric_id=? AND observed_at>=? AND observed_at<=?
            ORDER BY observed_at LIMIT 43201
            """, accountValues(account)
                + [.text(metricID), .real(from), .real(now.timeIntervalSince1970)], map: decode)
        return QuotaHistoryChartPoint.sample(samples, range: range, now: now)
    }

    /// 日均消耗用完整的七天分钟样本计算，与当前图表范围和抽样精度无关。
    /// 一次读取账号的所有指标，菜单不为每个模型启动独立数据库查询；全库已有十万条上限。
    func dailyRates(account: QuotaHistoryAccount, now: Date = Date()) throws -> [String: QuotaHistoryDailyRate] {
        guard FileManager.default.fileExists(atPath: database.url.path) else { return [:] }
        try prepare()
        let samples = try database.query("""
            SELECT payload FROM quota_history_samples WHERE mode=? AND provider=? AND account_key=?
              AND observed_at>=? AND observed_at<=? ORDER BY observed_at LIMIT 100000
            """, accountValues(account) + [.real(now.addingTimeInterval(-7 * 86_400).timeIntervalSince1970),
                                          .real(now.timeIntervalSince1970)], map: decode)
        var result: [String: QuotaHistoryDailyRate] = [:]
        for (metric, points) in Dictionary(grouping: samples, by: \.metricID) {
            if let latest = points.last, let rate = QuotaHistoryPoint.usedPerDay(points, now: now) {
                result[metric] = QuotaHistoryDailyRate(basis: latest.basis, value: rate)
            }
        }
        return result
    }

    /// 清除账号与时间水位在同一个事务中提交；旧内存快照不会因下一次无关通知重新写回。
    func clear(account: QuotaHistoryAccount, generation expected: UInt64, now: Date = Date()) throws {
        guard expected == generation else { throw CancellationError() }
        try prepare()
        try database.transaction {
            // 水位同时覆盖已保存的未来容差样本；系统时钟回拨时也不能让被清除的点再次复活。
            let latest = try database.query("SELECT MAX(observed_at) FROM quota_history_samples WHERE mode=? AND provider=? AND account_key=?", accountValues(account)) {
                sqlite3_column_type($0, 0) == SQLITE_NULL ? now.timeIntervalSince1970 : sqlite3_column_double($0, 0)
            }.first ?? now.timeIntervalSince1970
            try database.execute("DELETE FROM quota_history_samples WHERE mode=? AND provider=? AND account_key=?", accountValues(account))
            try database.execute("INSERT INTO quota_history_meta(key,value) VALUES(?,?) ON CONFLICT(key) DO UPDATE SET value=MAX(value,excluded.value)",
                                 [.text(Self.clearKey(account)), .real(max(latest, now.timeIntervalSince1970))])
        }
    }

    /// 维护服务先暂停并推进本 actor 世代，再由原跨模块事务删除样本。
    /// 此表保留删除水位，不包含额度事实；全量清理也不能把它删掉后重新导入旧快照。
    private func prepare() throws {
        guard !isPrepared else { return }
        try database.execute("""
            CREATE TABLE IF NOT EXISTS quota_history_samples(
              mode TEXT NOT NULL,provider TEXT NOT NULL,account_key TEXT NOT NULL,metric_id TEXT NOT NULL,
              bucket INTEGER NOT NULL,observed_at REAL NOT NULL,payload BLOB NOT NULL,
              PRIMARY KEY(mode,provider,account_key,metric_id,bucket))
            """)
        try database.execute("CREATE INDEX IF NOT EXISTS quota_history_observed ON quota_history_samples(observed_at)")
        try database.execute("CREATE TABLE IF NOT EXISTS quota_history_meta(key TEXT PRIMARY KEY,value REAL NOT NULL)")
        isPrepared = true
    }

    private func prune(now: Date) throws {
        let cutoff = now.addingTimeInterval(-Self.retention).timeIntervalSince1970
        try database.execute("DELETE FROM quota_history_samples WHERE observed_at<?", [.real(cutoff)])
        // 过期账号删除水位也有界回收；同一时间以前的缓存早已被保留期限拒绝，不能再导入。
        try database.execute("DELETE FROM quota_history_meta WHERE key LIKE 'cleared.account.%' AND value<?", [.real(cutoff)])
        let count = try database.scalarInt("SELECT COUNT(*) FROM quota_history_samples") ?? 0
        if count > Int64(Self.maximumSamples) {
            try database.execute("DELETE FROM quota_history_samples WHERE rowid IN (SELECT rowid FROM quota_history_samples ORDER BY observed_at LIMIT ?)",
                                 [.integer(count - Int64(Self.maximumSamples))])
        }
    }

    private func clearedAfter(key: String) throws -> TimeInterval {
        try database.query("SELECT value FROM quota_history_meta WHERE key=?", [.text(key)]) {
            sqlite3_column_double($0, 0)
        }.first ?? -Double.greatestFiniteMagnitude
    }

    private func accountValues(_ account: QuotaHistoryAccount) -> [AnalyticsDatabase.Value] {
        [.text(account.mode), .text(account.provider.rawValue), .text(account.accountKey)]
    }

    private static func clearKey(_ account: QuotaHistoryAccount) throws -> String {
        let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys]
        return "cleared.account." + (try encoder.encode(account)).base64EncodedString()
    }

    private func decode(_ statement: OpaquePointer) throws -> QuotaHistoryPoint {
        guard let bytes = sqlite3_column_blob(statement, 0) else { throw QuotaHistoryError.invalidPayload }
        return try JSONDecoder().decode(QuotaHistoryPoint.self,
            from: Data(bytes: bytes, count: Int(sqlite3_column_bytes(statement, 0))))
    }
}
