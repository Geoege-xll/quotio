import Foundation

/// CPA 展示模型只计算共享账本的投影，不读取网络、消费队列或修改采集偏好。
/// 旧版累计值没有日期与模型维度，必须保持原口径，不能在切换筛选后显示伪造的零。
nonisolated struct CPAUsageStatisticsPresentation {
    let usage: UsageStatisticsPresentation
    let totals: UsageTotals
    let available: Bool
    let isLegacy: Bool
    let providers: [String]
    let models: [String]

    init(snapshot: UsageLedgerSnapshot, legacyTotals: UsageTotals?, state: UsageCollectionState,
         period: UsageStatisticsPeriod, provider: String?, model: String?, now: Date,
         calendar: Calendar = .current) {
        self.init(buckets: snapshot.buckets, hasSavedData: snapshot.lastCollectedAt != nil,
                  legacyTotals: legacyTotals, state: state, period: period,
                  provider: provider, model: model, now: now, calendar: calendar)
    }

    /// 仪表盘只依赖影响统计结果的字段，不把持续变化的采集时间带入图表观察链。
    /// 保留快照初始化入口，其他调用方无需改变既有统计口径。
    init(buckets: [UsageBucket], hasSavedData: Bool, legacyTotals: UsageTotals?, state: UsageCollectionState,
         period: UsageStatisticsPeriod, provider: String?, model: String?, now: Date,
         calendar: Calendar = .current) {
        providers = Set(buckets.map(\.provider)).sorted()
        models = Set(buckets.filter { provider == nil || $0.provider == provider }.map(\.model)).sorted()
        let interval = period.interval(now: now, start: now, end: now, calendar: calendar)
        let projection = UsageStatisticsPresentation(buckets: buckets, interval: interval, provider: provider, model: model)
        let summary = projection.summary(legacyTotals: legacyTotals,
                                         hasSavedData: hasSavedData, state: state)
        usage = projection
        totals = summary.totals
        available = summary.available
        isLegacy = summary.isLegacy
    }
}
