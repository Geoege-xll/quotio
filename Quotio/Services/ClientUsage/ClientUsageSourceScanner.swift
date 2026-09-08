import Foundation

/// 每个客户端独享一个扫描actor，保证同来源缓存串行访问，同时三个来源不会互相等待磁盘扫描。
/// 普通Swift Task的取消会传递到actor同步工作，解析器在块/行边界检查取消。
actor ClientUsageSourceScanner {
    let source: ClientUsageSource
    let homeDirectory: String
    let environment: [String: String]
    let cacheURL: URL
    private let store: ClientUsageSQLiteStore
    init(source: ClientUsageSource, homeDirectory: String, environment: [String: String], cacheURL: URL, databaseURL: URL? = nil) {
        self.source = source; self.homeDirectory = homeDirectory; self.environment = environment; self.cacheURL = cacheURL
        // 每个来源复用连接；文件水位按轮读取，历史记录只保留在 SQL 中，不随 actor 常驻。
        self.store = ClientUsageSQLiteStore(databaseURL: databaseURL ?? AnalyticsDatabase.storeURL(forLegacyURL: cacheURL))
    }
    func collect(progress: @escaping ClientUsageProgressHandler) throws -> ClientUsageScan {
        try Task.checkCancellation()
        switch source {
        case .pi:
            return try PiClientUsageSource(homeDirectory: homeDirectory, environment: environment)
                .collect(cacheURL: cacheURL, cacheStore: store, progress: progress, incremental: true)
        case .claude:
            return try ClaudeClientUsageSource(homeDirectory: homeDirectory, environment: environment)
                .collect(cacheURL: cacheURL, cacheStore: store, progress: progress, incremental: true)
        case .codex:
            return try CodexClientUsageSource(homeDirectory: homeDirectory, environment: environment)
                .collect(cacheURL: cacheURL, cacheStore: store, progress: progress, projectRecords: false, incremental: true)
        case .opencode:
            return try OpenCodeClientUsageSource(homeDirectory: homeDirectory, environment: environment)
                .collect(cacheURL: cacheURL, cacheStore: store, progress: progress, incremental: true)
        }
    }

    /// 维护页释放连接中可能由兼容读取产生的临时数组；不触碰可重放的持久扫描事实。
    func releaseMemoryCaches() {
        store.clearMemoryCaches()
    }
}
