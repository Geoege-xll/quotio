import Foundation

/// 客户端用量独立账本：后台扫描和 SQLite 增量事务都留在 actor，UI只接收脱敏快照。
/// 不将 CPA 事件再加进此账本，消除客户端和网关两份记录之间无法关联时的双计风险。
actor ClientUsageEngine {
    enum ArchiveError: Error { case unsafePath, invalidArchive, writeFailed }
    private let url: URL
    private let store: ClientUsageSQLiteStore
    private let homeDirectory: String
    private let environment: [String: String]
    private let scanners: [ClientUsageSource: ClientUsageSourceScanner]
    private let scanOverride: (@Sendable (ClientUsageSource, @escaping ClientUsageProgressHandler) async throws -> ClientUsageScan)?

    init(url: URL? = nil, databaseURL: URL? = nil, homeDirectory: String = FileManager.default.homeDirectoryForCurrentUser.path,
         environment: [String: String] = ProcessInfo.processInfo.environment,
         scanOverride: (@Sendable (ClientUsageSource, @escaping ClientUsageProgressHandler) async throws -> ClientUsageScan)? = nil) {
        self.homeDirectory = homeDirectory; self.environment = environment
        let root = URL(fileURLWithPath: homeDirectory).appendingPathComponent("Library/Application Support")
        let ledgerURL = url ?? root.appendingPathComponent("Quotio/ClientUsage/ledger-v1.json")
        self.url = ledgerURL
        // 旧 url 只作为导入来源；生产三模块共享一个库，临时 home/url 测试仍完全隔离。
        let sqliteURL = databaseURL ?? (url.map(AnalyticsDatabase.storeURL(forLegacyURL:)) ?? AnalyticsDatabase.defaultURL(homeDirectory: homeDirectory))
        self.store = ClientUsageSQLiteStore(databaseURL: sqliteURL)
        self.scanOverride = scanOverride
        self.scanners = Dictionary(uniqueKeysWithValues: ClientUsageSource.allCases.map { source in
            (source, ClientUsageSourceScanner(source: source, homeDirectory: homeDirectory, environment: environment,
                cacheURL: ledgerURL.deletingLastPathComponent().appendingPathComponent("ScanCache/" + source.rawValue + ".json"),
                databaseURL: sqliteURL))
        })
    }
    /// 显式的完整事实读取仅供导出、兼容验证使用；结果不缓存在引擎中。
    /// 生产页面统一走 loadPresentation，不再让几十万条记录随应用生命周期常驻。
    func load() throws -> ClientUsageSnapshot { try store.loadLedger(legacyURL: url) }

    func loadPresentation(calendar: Calendar = .current) throws -> ClientUsageDisplaySnapshot {
        try Task.checkCancellation()
        _ = try store.loadLedgerMetadata(legacyURL: url)
        return try store.loadDisplay(calendar: calendar)
    }

    func refreshPresentation(calendar: Calendar = .current) async throws -> ClientUsageDisplaySnapshot {
        _ = try await refresh()
        return try loadPresentation(calendar: calendar)
    }

    /// 四个来源由独立 actor 并发扫描，每完成一个即保存并发布该来源的小型统计结果。
    /// 慢Codex不会阻塞Claude或OpenCode；来源解析失败只影响本来源，永久账本失败仍向上抛出。
    func refresh(onEvent: @escaping @Sendable (ClientUsageRefreshEvent) -> Void = { _ in }) async throws -> ClientUsageDisplaySnapshot {
        _ = try store.loadLedgerMetadata(legacyURL: url)
        let workers = scanners
        let override = scanOverride
        try await withThrowingTaskGroup(of: ClientUsageScan.self) { group in
            for source in ClientUsageSource.allCases {
                group.addTask {
                    let progress: ClientUsageProgressHandler = { onEvent(.progress($0)) }
                    progress(ClientUsageProgress(source: source))
                    do {
                        if let override { return try await override(source, progress) }
                        guard let worker = workers[source] else { throw CancellationError() }
                        return try await worker.collect(progress: progress)
                    } catch is CancellationError { throw CancellationError() }
                    catch {
                        // 保留其它来源已经完成的结果，失败不伪装为可靠零。
                        return ClientUsageScan(source: source, codexReadErrors: source == .codex, hasErrors: true)
                    }
                }
            }
            for try await scan in group {
                try Task.checkCancellation()
                onEvent(.saving(scan.source))
                try store.mergeIncrementally(scans: [scan], at: Date())
                let display = try loadPresentation()
                try Task.checkCancellation()
                onEvent(.completed(scan.source, display))
            }
        }
        try Task.checkCancellation()
        return try loadPresentation()
    }

    /// 保留兼容验证所需的全量返回值；生产刷新调用存储层增量提交后只读取汇总。
    func merge(scans: [ClientUsageScan], at date: Date) throws -> ClientUsageSnapshot {
        _ = try store.loadLedgerMetadata(legacyURL: url)
        try store.mergeIncrementally(scans: scans, at: date)
        return try load()
    }

    /// 调用者已暂停并等待采集结束，随后逐个等待扫描 actor 释放可重建内存。
    /// 持久化扫描水位和检查点不会删除，源日志消失时仍能恢复已经采集的历史。
    func releaseMemoryCaches() async {
        store.clearMemoryCaches()
        for worker in scanners.values { await worker.releaseMemoryCaches() }
    }
}
