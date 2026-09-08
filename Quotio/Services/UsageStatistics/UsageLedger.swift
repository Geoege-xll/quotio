import Foundation

/// CPA 队列的唯一持久化入口。事件、日汇总、历史基线和采集水位共用统计 SQLite，
/// 旧 JSON 仅作一次迁移输入；actor 串行提交后才发布快照，界面不会观察到半批数据。
actor UsageLedger {
    enum LedgerError: Error { case unsupportedVersion }
    private let calendar: Calendar
    private let eventStore: CPAUsageEventStore
    private let legacyLedgerURL: URL?
    private let legacyEventURL: URL?
    private var cached: UsageLedgerSnapshot?
    private var bucketsByID: [String: UsageBucket] = [:]
    private var historicalBuckets: [UsageBucket] = []
    private var historicalCollectedAt: Date?

    /// 兼容旧注入入口；测试 JSON 路径只决定一次迁移来源，目标库仍位于测试自己的目录。
    init(url: URL, calendar: Calendar = .current) {
        self.calendar = calendar
        self.legacyLedgerURL = url
        self.legacyEventURL = url.deletingLastPathComponent().appendingPathComponent("usage-events.sqlite")
        self.eventStore = CPAUsageEventStore(url: AnalyticsDatabase.storeURL(forLegacyURL: url))
    }

    init(databaseURL: URL, legacyLedgerURL: URL? = nil, legacyEventURL: URL? = nil, calendar: Calendar = .current) {
        self.calendar = calendar
        self.legacyLedgerURL = legacyLedgerURL
        self.legacyEventURL = legacyEventURL
        self.eventStore = CPAUsageEventStore(url: databaseURL)
    }

    func load() throws -> UsageLedgerSnapshot {
        if let cached { return cached }
        try eventStore.migrateLegacyStorage(ledgerURL: legacyLedgerURL, eventURL: legacyEventURL, calendar: calendar)
        let snapshot = try eventStore.ledgerSnapshot()
        let history = try eventStore.historicalSnapshot()
        historicalBuckets = history.buckets; historicalCollectedAt = history.collectedAt
        bucketsByID = Dictionary(uniqueKeysWithValues: snapshot.buckets.map { ($0.id, $0) })
        cached = snapshot
        return snapshot
    }

    /// 事务失败时不修改内存快照；调用者继续保留已经出队的批次并重试。
    /// 每批仅从 SQL 取回变化日桶，空队列心跳不会再次读取、解码和排序全部历史。
    func ingest(_ records: [UsageRecord], collectedAt: Date) throws -> UsageLedgerSnapshot {
        var next = try load()
        let events = records.map { CPAUsageEvent(record: $0, ledgerDay: calendar.startOfDay(for: $0.timestamp)) }
        let changed = try eventStore.ingest(events, collectedAt: collectedAt, calendar: calendar)
        if !changed.isEmpty {
            for bucket in changed { bucketsByID[bucket.id] = bucket }
            next.buckets = bucketsByID.values.sorted { $0.id < $1.id }
        }
        next.firstCollectedAt = next.firstCollectedAt ?? collectedAt
        next.lastCollectedAt = max(next.lastCollectedAt ?? collectedAt, collectedAt)
        cached = next
        return next
    }

    /// 全时间目录仅用于完整筛选草稿，保留各页面原有的时间窗选项行为。
    func filterOptions() throws -> CPAUsageFilterOptions {
        _ = try load()
        let history = CPAUsageHistoricalReport(history: historicalBuckets, collectedAt: historicalCollectedAt,
                                               query: CPAUsageQuery(), calendar: calendar)
        return try history.mergingOptions(into: eventStore.filterOptions())
    }

    func queryEvents(_ query: CPAUsageQuery) throws -> CPAUsageEventPage {
        _ = try load()
        let history = CPAUsageHistoricalReport(history: historicalBuckets, collectedAt: historicalCollectedAt,
                                               query: query, calendar: calendar)
        // 真实明细指标和分页不混入历史请求；日期汇总及覆盖状态由独立字段交给页面展示。
        return history.mergingSummary(into: try eventStore.query(query), includeHistoricalMetrics: false)
    }

    /// SQL 负责明细聚合，旧日汇总保留既有覆盖范围语义；无法恢复的字段继续显示未知。
    func queryDashboard(_ query: CPAUsageQuery, dimension: CPAUsageDimension,
                        metric: CPAUsageChartMetric, limit: Int) throws -> CPAUsageDashboardReport {
        _ = try load()
        let history = CPAUsageHistoricalReport(history: historicalBuckets, collectedAt: historicalCollectedAt,
                                               query: query, calendar: calendar)
        let report = try eventStore.dashboard(query, dimension: dimension, metric: metric, limit: limit,
                                             includesHistory: !history.buckets.isEmpty)
        return history.merging(into: report, query: query, dimension: dimension, metric: metric, limit: limit)
    }

    func queryPricing(_ query: CPAUsageQuery) throws -> CPAUsagePricingReport {
        _ = try load()
        let history = CPAUsageHistoricalReport(history: historicalBuckets, collectedAt: historicalCollectedAt,
                                               query: query, calendar: calendar)
        // 模型行由真实明细与可纳入筛选的日汇总共同提供；未配置价格的历史模型也能被编辑。
        return try history.merging(into: eventStore.pricing(query), prices: eventStore.modelPrices())
    }

    func savePrice(_ price: CPAModelPrice) throws {
        _ = try load()
        try eventStore.savePrice(price)
    }

    /// 维护操作已等待采集完成；释放可从 SQL 重建的日桶，不能删除事实或价格配置。
    func releaseMemoryCaches() {
        cached = nil
        bucketsByID.removeAll()
        historicalBuckets.removeAll()
        historicalCollectedAt = nil
    }
}
