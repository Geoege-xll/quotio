import Foundation

/// 页面只对账本的日汇总做纯计算；不读取队列、不修改账本，保证筛选不会消费或丢失记录。
nonisolated enum UsageStatisticsPeriod: String, CaseIterable, Identifiable {
    case today, week, month, all, custom
    var id: Self { self }
    var titleKey: String { "usage.period." + rawValue }

    /// 自定义范围包括首尾两天。使用 Calendar 跨日，而不是固定加 86400 秒，兼容夏令时。
    func interval(now: Date, start: Date, end: Date, calendar: Calendar) -> DateInterval? {
        switch self {
        case .today: return calendar.dateInterval(of: .day, for: now)
        case .week:
            // 与 AIUsage 一致固定周一开周，不受系统地区的「周日为首日」设置影响。
            let today = calendar.startOfDay(for: now)
            let offset = (calendar.component(.weekday, from: now) + 5) % 7
            guard let lower = calendar.date(byAdding: .day, value: -offset, to: today),
                  let upper = calendar.date(byAdding: .day, value: 7, to: lower) else { return nil }
            return DateInterval(start: lower, end: upper)
        case .month: return calendar.dateInterval(of: .month, for: now)
        case .all: return nil
        case .custom:
            let lower = calendar.startOfDay(for: min(start, end))
            let lastDay = calendar.startOfDay(for: max(start, end))
            guard let upper = calendar.date(byAdding: .day, value: 1, to: lastDay) else { return nil }
            return DateInterval(start: lower, end: upper)
        }
    }
}

nonisolated struct UsageStatisticsDay: Identifiable {
    let day: Date
    let totals: UsageTotals
    var id: Date { day }
}

/// 同名模型在不同提供商下分别排名，避免把不同路由的用量和成功率误合并。
nonisolated struct UsageStatisticsModel: Identifiable {
    let provider: String
    let model: String
    let totals: UsageTotals
    var id: String { "\(provider.utf8.count):\(provider)\(model)" }
}

nonisolated struct UsageStatisticsPresentation {
    let buckets: [UsageBucket]
    // 展示对象构建后不可变，汇总只计算一次，避免多个图表重复 reduce/group/sort。
    let totals: UsageTotals
    let days: [UsageStatisticsDay]
    let models: [UsageStatisticsModel]

    /// 连接状态只描述采集是否运行，不能决定已保存摘要的数据来源。
    /// 旧版 CPA 停止或读取失败后仍保留累计值；有 legacyTotals 就保持同一口径，
    /// 同时禁用无法应用到旧版累计值的筛选，避免拿空日账本覆盖为零。
    func summary(legacyTotals: UsageTotals?, hasSavedData: Bool, state: UsageCollectionState)
        -> (totals: UsageTotals, isLegacy: Bool, available: Bool) {
        if let legacyTotals {
            return (legacyTotals, true, true)
        }
        // 只有已保存过数据，或本次确认采集成功，空账本的零才具有确定含义。
        return (totals, false, hasSavedData || state == .live)
    }
    init(buckets: [UsageBucket], interval: DateInterval?, provider: String?, model: String?) {
        self.buckets = buckets.filter { bucket in
            // 区间右端不包含下一天凌晨，避免相邻日期统计双计。
            let inRange = interval.map { bucket.day >= $0.start && bucket.day < $0.end } ?? true
            return inRange && (provider == nil || bucket.provider == provider) && (model == nil || bucket.model == model)
        }
        totals = UsageTotals(buckets: self.buckets)
        days = Dictionary(grouping: self.buckets, by: \.day).map {
            UsageStatisticsDay(day: $0.key, totals: UsageTotals(buckets: $0.value))
        }.sorted { $0.day < $1.day }
        // 结构化的两段键避免提供商或模型名称中的分隔符造成错误合并。
        models = Dictionary(grouping: self.buckets) { [$0.provider, $0.model] }.map {
            UsageStatisticsModel(provider: $0.key[0], model: $0.key[1], totals: UsageTotals(buckets: $0.value))
        }.sorted {
            if $0.totals.totalTokens != $1.totals.totalTokens { return $0.totals.totalTokens > $1.totals.totalTokens }
            if $0.totals.requests != $1.totals.requests { return $0.totals.requests > $1.totals.requests }
            return $0.id < $1.id
        }
    }
}
