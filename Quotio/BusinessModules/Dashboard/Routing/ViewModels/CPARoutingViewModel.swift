import Foundation
import Observation

/// 配置读取可注入，回归测试不启动 CPA，也不接触用户管理密钥。
nonisolated protocol CPARoutingConfigurationClient: Sendable {
    func getRoutingStrategy() async throws -> String
    func getRequestRetry() async throws -> Int
}

extension ManagementAPIClient: CPARoutingConfigurationClient {}

/// 路由页唯一的展示状态。三个组件共享一次本地查询，仍由 UsageStatisticsStore
/// 独占 CPA 消费式队列；此模型没有任何 fetchUsageQueue 或配置写入入口。
@MainActor @Observable
final class CPARoutingViewModel {
    private(set) var snapshot = CPARoutingSnapshot.empty(now: .now)
    private(set) var isLoading = false
    private(set) var hasReadError = false
    private(set) var routingStrategy: String?
    private(set) var retryRounds: Int?
    private(set) var latestActivityID: String?
    private(set) var activities: [CPARoutingActivity] = []
    @ObservationIgnored private var generation = 0
    @ObservationIgnored private var configurationGeneration = 0
    @ObservationIgnored private var didLoadSnapshot = false
    @ObservationIgnored private var lastSuccessfulEventIDs = Set<String>()
    @ObservationIgnored private var lastSuccessfulStart: Date?

    var displayedEvents: [CPAUsageEvent] { snapshot.events }

    /// 舞台最多展示三个来源和三个上游。迟到的慢请求按采集顺序优先进入舞台，
    /// 避免新活动虽然存在，却因旧时间戳排在后面而找不到可见连线；明细列表仍保持
    /// 原有时间顺序。这里仅重排同一快照，不补查数据库，也不伪造额外节点。
    var stageEvents: [CPAUsageEvent] {
        let events = Dictionary((snapshot.events + (snapshot.arrivalEvents ?? [])).map { ($0.id, $0) },
                                uniquingKeysWith: { first, _ in first })
        let preferred = activities.compactMap { events[$0.id] }
        let preferredIDs = Set(preferred.map(\.id))
        return preferred + snapshot.events.filter { !preferredIDs.contains($0.id) }
    }

    func reload(now: Date = .now, activityClock: @MainActor () -> Date = { .now },
                load: @MainActor (Date) async throws -> CPARoutingSnapshot) async {
        generation &+= 1
        let requested = generation
        isLoading = true
        defer { if requested == generation { isLoading = false } }
        do {
            let next = try await load(now)
            // 新修订号、手动刷新或日期切换都可以发起更新；较早的异步结果不能
            // 覆盖较新的查询。取消离开页面的 task 也不能发布残留结果。
            guard requested == generation, !Task.isCancelled else { return }
            let receivedAt = activityClock()
            let activityEvents = next.arrivalEvents ?? next.events
            // 比较整批记录身份，而非仅比较第一条。慢请求完成后才上报，时间戳可能
            // 比当前首条更早；活动时钟从查询完成、记录到达界面的时刻开始计时。
            // 首次历史恢复和跨日恢复不重播，读取失败后的去重基线仍保留。
            if didLoadSnapshot, lastSuccessfulStart == next.start, next.executions > 0 {
                var routes = Set<String>()
                let arrivals = activityEvents.filter { !lastSuccessfulEventIDs.contains($0.id) }
                    .map { CPARoutingActivity(event: $0, receivedAt: receivedAt) }
                    .filter { routes.insert($0.sourceID + "|" + $0.targetID + "|" + $0.outcome.rawValue).inserted }
                    .prefix(CPARoutingActivity.maximumConcurrent)
                if let first = arrivals.first { latestActivityID = first.id }
                let newIDs = Set(arrivals.map(\.id))
                activities = Array((Array(arrivals) + activities.filter {
                    !newIDs.contains($0.id) && $0.isRecent(at: receivedAt)
                }).prefix(CPARoutingActivity.maximumRetained))
            } else {
                activities = []
                latestActivityID = nil
            }
            snapshot = next
            lastSuccessfulEventIDs = Set(activityEvents.map(\.id))
            lastSuccessfulStart = next.start
            didLoadSnapshot = true
            hasReadError = false
        } catch {
            guard requested == generation, !Task.isCancelled else { return }
            snapshot = .empty(now: now)
            latestActivityID = nil
            activities = []
            hasReadError = true
        }
    }

    /// 当前配置与历史执行分开读取。停止服务和读取失败保留未知，绝不回退到
    /// 看似可信的“轮询／3 次”。配置读取不阻塞本地执行记录更新。
    func reloadConfiguration(client: (any CPARoutingConfigurationClient)?) async {
        configurationGeneration &+= 1
        let requested = configurationGeneration
        routingStrategy = nil
        retryRounds = nil
        guard let client else { return }
        async let strategy = try? client.getRoutingStrategy()
        async let retry = try? client.getRequestRetry()
        let values = await (strategy, retry)
        guard requested == configurationGeneration, !Task.isCancelled else { return }
        routingStrategy = values.0
        retryRounds = values.1.flatMap { $0 >= 0 ? $0 : nil }
    }
}
