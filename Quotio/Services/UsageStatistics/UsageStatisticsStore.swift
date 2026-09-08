import Foundation
import Observation

/// 注入协议让队列消费顺序与磁盘故障可在完全隔离的测试中验证。
protocol UsageStatisticsClient: Sendable {
    func getUsageStatisticsEnabled() async throws -> Bool
    func setUsageStatisticsEnabled(_ enabled: Bool) async throws
    func fetchUsageQueue(count: Int) async throws -> UsageQueueBatch
    func fetchUsageStats() async throws -> UsageStats
}

extension ManagementAPIClient: UsageStatisticsClient {}

nonisolated enum UsageCollectionState: Sendable {
    case stopped, loading, live, disabled, unsupported, failed, storageError, legacy
}

/// 全应用唯一的用量队列消费者。视图只读快照；采集不依赖窗口 task 或配额刷新频率。
/// 弹出式队列没有确认协议，因此网络响应丢失/进程在落盘前崩溃无法保证零丢失，
/// 本服务不自动重放网络请求，并在成功取得批次后优先持久化再更新界面。
@MainActor @Observable
final class UsageStatisticsStore {
    private(set) var snapshot = UsageLedgerSnapshot()
    /// 统计内容单独发布：采集心跳只更新时间，不能反复驱动全年日桶的筛选、排序及图表重建。
    /// 数组使用值语义共享底层存储，仅在真实统计变化时通知观察者。
    private(set) var statisticsBuckets: [UsageBucket] = []
    private(set) var hasCollectedData = false
    /// 修订号不随空队列心跳变化，页面据此合并查询；事件与日汇总已在同一事务提交。
    private(set) var statisticsRevision = 0
    private(set) var priceRevision = 0
    private(set) var state: UsageCollectionState = .stopped
    private(set) var isRefreshing = false
    private(set) var legacyTotals: UsageTotals?
    private(set) var hasMalformedRecords = false
    @ObservationIgnored private let ledger: UsageLedger
    @ObservationIgnored private var client: (any UsageStatisticsClient)?
    @ObservationIgnored private var loop: Task<Void, Never>?
    @ObservationIgnored private var activeSession: UUID?
    @ObservationIgnored private var pending: [UsageRecord] = []
    @ObservationIgnored private var busy = false
    @ObservationIgnored private var queueUnsupported = false
    @ObservationIgnored private var maintenanceSuspended = false
    @ObservationIgnored private var maintenanceResumeClient: (any UsageStatisticsClient)?
    @ObservationIgnored private var maintenanceResumeSession: UUID?
    @ObservationIgnored private var drainWaiters: [CheckedContinuation<Void, Never>] = []
    @ObservationIgnored private var storageGeneration = UUID()

    init(ledger: UsageLedger? = nil) {
        let root = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        self.ledger = ledger ?? UsageLedger(databaseURL: AnalyticsDatabase.defaultURL(),
            legacyLedgerURL: root.appendingPathComponent("Quotio/UsageStatistics/ledger-v1.json"),
            legacyEventURL: root.appendingPathComponent("Quotio/UsageStatistics/usage-events.sqlite"))
    }
    var hasData: Bool { snapshot.lastCollectedAt != nil || legacyTotals != nil }
    var totals: UsageTotals { legacyTotals ?? snapshot.totals }
    var statusKey: String {
        switch state {
        case .stopped: return "usage.status.stopped"
        case .loading: return "usage.status.loading"
        case .live: return hasMalformedRecords ? "usage.status.partial" : "usage.status.live"
        case .disabled: return "usage.status.disabled"
        case .unsupported: return "usage.status.unsupported"
        case .failed: return "usage.status.failed"
        case .storageError: return "usage.status.storageError"
        case .legacy: return "usage.status.legacy"
        }
    }

    func restore() async {
        guard !maintenanceSuspended else { return }
        let generation = storageGeneration
        do {
            let saved = try await ledger.load()
            guard !maintenanceSuspended, generation == storageGeneration else { return }
            // 页面恢复与后台采集可能交错，旧磁盘快照不能倒退已发布的采集时间。
            if saved.lastCollectedAt ?? .distantPast >= snapshot.lastCollectedAt ?? .distantPast {
                publish(saved)
            }
        } catch { state = .storageError }
    }

    func start(baseURL: String, managementKey: String, sessionID: UUID) {
        start(client: ManagementAPIClient(baseURL: baseURL + "/v0/management", authKey: managementKey), sessionID: sessionID)
    }

    func start(client: any UsageStatisticsClient, sessionID: UUID) {
        // 维护中若代理重新启动，记录最新目标，等数据库操作完成后再恢复消费者。
        if maintenanceSuspended {
            maintenanceResumeClient = client
            maintenanceResumeSession = sessionID
            return
        }
        guard activeSession != sessionID else { return }
        loop?.cancel()
        activeSession = sessionID
        self.client = client
        queueUnsupported = false; legacyTotals = nil; state = .loading
        loop = Task { [weak self] in
            while !Task.isCancelled {
                guard let self, self.activeSession == sessionID else { return }
                await self.refresh()
                do { try await Task.sleep(for: .seconds(2)) } catch { return }
            }
        }
    }

    func stop() {
        if maintenanceSuspended { maintenanceResumeClient = nil; maintenanceResumeSession = nil }
        loop?.cancel(); loop = nil; activeSession = nil; client = nil
        state = .stopped
        // 已收集账本和待落盘批次保留，停止/重启不会把历史数字清零。
    }

    func enableCollection() async {
        guard let client else { return }
        do { try await client.setUsageStatisticsEnabled(true); await refresh() }
        catch { state = .failed }
    }

    func refresh() async {
        // 同时点击多个页面刷新只会唤起一个消费者；actor 重入也不能并发弹出同一队列。
        guard !maintenanceSuspended, !busy else { return }
        busy = true; isRefreshing = true
        defer {
            busy = false; isRefreshing = false
            let waiters = drainWaiters
            drainWaiters.removeAll()
            for waiter in waiters { waiter.resume() }
        }
        let session = activeSession
        do {
            publish(try await ledger.load())
            if !pending.isEmpty {
                publish(try await persistConsumedBatch(pending))
                pending = []
            }
        } catch { state = .storageError; return }
        guard let client, session != nil else { return }
        do {
            guard try await client.getUsageStatisticsEnabled() else {
                if activeSession == session { state = .disabled }
                return
            }
            guard activeSession == session, !Task.isCancelled else { return }
            if queueUnsupported { try await refreshLegacy(client: client, session: session); return }
            // 每轮最多 8 批；连续满批时很快进入下一轮，后台负载有界且及时排空短保留队列。
            for _ in 0..<8 {
                let batch: UsageQueueBatch
                do { batch = try await client.fetchUsageQueue(count: 500) }
                catch APIError.httpError(404) {
                    guard activeSession == session, !Task.isCancelled else { return }
                    queueUnsupported = true
                    try await refreshLegacy(client: client, session: session)
                    return
                }
                // 即使启停发生在网络等待期间，已被弹出的有效记录也先保存；随后再拒绝旧会话状态。
                pending = batch.records
                if batch.invalidCount > 0 { hasMalformedRecords = true }
                do {
                    publish(try await persistConsumedBatch(pending))
                    pending = []
                } catch {
                    if activeSession == session { state = .storageError }
                    return
                }
                guard activeSession == session, !Task.isCancelled else { return }
                if state != .live { state = .live }
                if batch.records.count + batch.invalidCount < 500 { return }
            }
        } catch APIError.httpError(404) {
            if activeSession == session { state = .unsupported }
        } catch {
            if activeSession == session, !Task.isCancelled { state = .failed }
        }
    }

    /// 队列是消费式接口：停止轮询可以取消后续网络请求，但已返回的批次必须完成提交。
    /// 独立任务只捕获 Sendable 的 actor 和脱敏记录，不继承轮询取消；等待落盘结束后，
    /// refresh 再检查 session，避免旧会话把状态恢复为 live，同时不丢弃已出队数据。
    private func persistConsumedBatch(_ records: [UsageRecord]) async throws -> UsageLedgerSnapshot {
        let ledger = ledger
        let collectedAt = Date()
        return try await Task.detached(priority: .utility) {
            try await ledger.ingest(records, collectedAt: collectedAt)
        }.value
    }

    /// 完整筛选面板只读取本地目录，不刷新 CPA 队列，也不改变当前统计修订号。
    func queryFilterOptions() async throws -> CPAUsageFilterOptions {
        try await ledger.filterOptions()
    }

    /// 使用记录只查询本地索引，不从弹窗启动第二个队列消费者。
    func queryUsageRecords(_ query: CPAUsageQuery) async throws -> CPAUsageEventPage {
        try await ledger.queryEvents(query)
    }

    /// 完整快照继续供明细查询触发器与采集时间使用，统计区域不再观察它的高频心跳。
    /// 首次成功采集即使是空队列，也必须从“尚无数据”切换为真实的零用量。
    private func publish(_ next: UsageLedgerSnapshot) {
        if statisticsBuckets != next.buckets || hasCollectedData != (next.lastCollectedAt != nil) {
            statisticsRevision &+= 1
        }
        if statisticsBuckets != next.buckets { statisticsBuckets = next.buckets }
        let collected = next.lastCollectedAt != nil
        if hasCollectedData != collected { hasCollectedData = collected }
        snapshot = next
    }

    func queryDashboard(_ selection: CPAUsageSelection, dimension: CPAUsageDimension,
                        metric: CPAUsageChartMetric, limit: Int, now: Date) async throws -> CPAUsageDashboardReport {
        try await ledger.queryDashboard(selection.query(now: now, page: 1, pageSize: 1),
                                        dimension: dimension, metric: metric, limit: limit)
    }

    func queryPricing(_ selection: CPAUsageSelection, now: Date) async throws -> CPAUsagePricingReport {
        try await ledger.queryPricing(selection.query(now: now, page: 1, pageSize: 1))
    }

    func saveModelPrice(_ price: CPAModelPrice) async throws {
        try await ledger.savePrice(price)
        priceRevision &+= 1
    }

    /// CPA 队列读出即消费，维护前必须等已取出的批次完成落盘，不能仅取消任务就删除数据库。
    /// 额外等待手动 refresh 的 busy 屏障，覆盖它不属于自动 loop 的情况。
    func suspendForMaintenance() async throws {
        guard !maintenanceSuspended else { return }
        maintenanceSuspended = true
        storageGeneration = UUID()
        maintenanceResumeClient = client
        maintenanceResumeSession = activeSession
        let activeLoop = loop
        loop = nil
        activeSession = nil; client = nil
        // 先让当前 refresh 自然结束。取消承载网络请求的 loop 可能使“已经出队、尚未收到”的
        // 批次丢失；只有 busy 已结束、消费响应已保存后，才取消循环中剩余的睡眠。
        if busy { await withCheckedContinuation { drainWaiters.append($0) } }
        activeLoop?.cancel()
        await activeLoop?.value
        if !pending.isEmpty {
            publish(try await persistConsumedBatch(pending))
            pending = []
        }
    }

    func resumeAfterMaintenance() {
        guard maintenanceSuspended else { return }
        let client = maintenanceResumeClient
        let session = maintenanceResumeSession
        maintenanceResumeClient = nil; maintenanceResumeSession = nil
        maintenanceSuspended = false
        if let client, let session { start(client: client, sessionID: session) }
    }

    func clearMemoryCaches() async { await ledger.releaseMemoryCaches() }

    func reloadAfterMaintenance() async throws {
        storageGeneration = UUID()
        legacyTotals = nil
        hasMalformedRecords = false
        // 先失效界面；即使重读遇到磁盘故障，也不能让旧汇总继续作为删除后的有效统计。
        publish(UsageLedgerSnapshot())
        // 即使清除前已经为空，也让持有旧查询结果的页面失效后重新读取。
        statisticsRevision &+= 1
        await ledger.releaseMemoryCaches()
        do { publish(try await ledger.load()) }
        catch { state = .storageError; throw error }
    }

    private func refreshLegacy(client: any UsageStatisticsClient, session: UUID?) async throws {
        let stats = try await client.fetchUsageStats()
        guard activeSession == session, !Task.isCancelled else { return }
        guard let usage = stats.usage, let requests = usage.totalRequests, let tokens = usage.totalTokens else {
            state = .unsupported; return
        }
        var totals = UsageTotals()
        totals.requests = requests; totals.totalTokens = tokens; totals.failures = usage.failureCount ?? 0
        totals.inputTokens = usage.inputTokens ?? 0; totals.outputTokens = usage.outputTokens ?? 0
        if legacyTotals != totals { legacyTotals = totals }
        if state != .legacy { state = .legacy }
        // 旧版是进程累计快照，不能每次累加进事件账本，否则轮询会造成重复计数。
    }
}
