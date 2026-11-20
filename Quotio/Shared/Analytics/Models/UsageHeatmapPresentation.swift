import Foundation

/// 热力图固定展示最近 52 周，周一在第一行。所有日期用 Calendar 递增，避免夏令时错位。
/// 图表窗口独立于摘要时间筛选，与全年活跃视图一致；非时间筛选（提供商、模型、来源、API Key、状态）仍生效，
/// 按 Tokens、费用或请求数计算色阶、活跃天数、峰值日与单日排行。
nonisolated struct UsageHeatmapPresentation {
    struct Day: Identifiable {
        let date: Date
        let totals: UsageTotals
        let models: [UsageStatisticsModel]
        let isFuture: Bool
        let isBeforeCollection: Bool
        let isInSelection: Bool
        let cost: CPAUsageCostEstimate
        let modelCosts: [String: CPAUsageCostEstimate]
        var id: Date { date }

        func value(_ metric: CPAUsageChartMetric) -> Double {
            switch metric {
            case .tokens: Double(totals.totalTokens)
            case .requests: Double(totals.requests)
            case .cost: cost.amount ?? 0
            }
        }
    }
    struct Week: Identifiable {
        let days: [Day]
        var id: Date { days[0].date }
    }
    let weeks: [Week]
    let thresholds: [Double]
    let totals: UsageTotals
    let activeDays: Int
    let peak: Day?
    let metric: CPAUsageChartMetric
    let cost: CPAUsageCostEstimate
    let hasSelection: Bool
    let costIdentity: CostIdentity

    struct CostIdentity: Equatable {
        let estimates: [String: CPAUsageCostEstimate]
        let partialDays: Set<Date>
    }

    /// 计算最近 52 周周一开周的起始本地日，确保 SQL 查询、历史合并与网格构造使用同一时间起点。
    static func windowStart(now: Date, calendar: Calendar = .current) -> Date {
        let anchor = calendar.startOfDay(for: now)
        let mondayOffset = (calendar.component(.weekday, from: anchor) + 5) % 7
        return calendar.date(byAdding: .day, value: -mondayOffset - 51 * 7, to: anchor) ?? anchor
    }

    init(buckets: [UsageBucket], now: Date, firstCollectedAt: Date?,
         metric: CPAUsageChartMetric = .tokens, calendar: Calendar = .current,
         costs: [String: CPAUsageCostEstimate] = [:], partialDays: Set<Date> = [],
         selectedStart: Date? = nil, selectedEnd: Date? = nil) {
        self.metric = metric
        self.costIdentity = CostIdentity(estimates: costs, partialDays: partialDays)
        let today = calendar.startOfDay(for: now)
        let start = Self.windowStart(now: now, calendar: calendar)
        self.hasSelection = selectedStart != nil || selectedEnd != nil
        let firstDay = firstCollectedAt.map { calendar.startOfDay(for: $0) }
        let grouped = Dictionary(grouping: buckets, by: { calendar.startOfDay(for: $0.day) })
        var weeks: [Week] = []
        for week in 0..<52 {
            let days = (0..<7).map { row in
                let date = calendar.date(byAdding: .day, value: week * 7 + row, to: start) ?? start
                let entries = grouped[date] ?? []
                let presentation = UsageStatisticsPresentation(buckets: entries, interval: nil, provider: nil, model: nil)
                var dayCost = CPAUsageCostEstimate(isPartial: partialDays.contains(date))
                var modelCosts: [String: CPAUsageCostEstimate] = [:]
                if metric == .cost {
                    for entry in entries {
                        let model = UsageStatisticsModel(provider: entry.provider, model: entry.model, totals: UsageTotals())
                        let estimate = costs[entry.id] ?? CPAUsageCostEstimate(isPartial: entry.requests > 0)
                        modelCosts[model.id, default: CPAUsageCostEstimate(isPartial: partialDays.contains(date))].add(estimate)
                        dayCost.add(estimate)
                    }
                }
                let sortedModels = presentation.models.sorted {
                    switch metric {
                    case .tokens: break
                    case .requests:
                        if $0.totals.requests != $1.totals.requests { return $0.totals.requests > $1.totals.requests }
                    case .cost:
                        let lhs = modelCosts[$0.id]?.amount ?? -1
                        let rhs = modelCosts[$1.id]?.amount ?? -1
                        if lhs != rhs { return lhs > rhs }
                    }
                    if $0.totals.totalTokens != $1.totals.totalTokens { return $0.totals.totalTokens > $1.totals.totalTokens }
                    if $0.totals.requests != $1.totals.requests { return $0.totals.requests > $1.totals.requests }
                    return $0.id < $1.id
                }
                let nextDay = calendar.date(byAdding: .day, value: 1, to: date) ?? date
                // SQL 的时间上界包含该时刻，而自然日右端不含次日凌晨。
                // 精确范围恰好结束于午夜时，午夜所在的新一天也可能含匹配事件。
                let intersects = (selectedStart.map { $0 < nextDay } ?? true)
                    && (selectedEnd.map { $0 >= date } ?? true)
                return Day(date: date, totals: presentation.totals, models: sortedModels,
                           isFuture: date > today, isBeforeCollection: entries.isEmpty && firstDay.map { date < $0 } == true,
                           isInSelection: intersects, cost: dayCost, modelCosts: modelCosts)
            }
            weeks.append(Week(days: days))
        }
        self.weeks = weeks
        let visible = weeks.flatMap(\.days).filter { !$0.isFuture }
        let metricValue: (Day) -> Double = { $0.value(metric) }
        cost = visible.reduce(into: CPAUsageCostEstimate()) { $0.add($1.cost) }
        let positive = visible.map(metricValue).filter { $0 > 0 }.sorted()
        thresholds = positive.isEmpty ? [] : [positive[(positive.count - 1) / 4], positive[(positive.count - 1) / 2], positive[(positive.count - 1) * 3 / 4]]
        activeDays = positive.count
        peak = visible.filter { metricValue($0) > 0 }.max { metricValue($0) < metricValue($1) }
        totals = UsageTotals(buckets: buckets.filter { calendar.startOfDay(for: $0.day) >= start && calendar.startOfDay(for: $0.day) <= today })
    }

    /// 使用正用量的四分位色阶，避免少数峰值日令其余活跃日全部变成近乎不可见。
    func intensity(_ value: Double) -> Int {
        guard value > 0, thresholds.count == 3 else { return 0 }
        if value <= thresholds[0] { return 1 }
        if value <= thresholds[1] { return 2 }
        if value <= thresholds[2] { return 3 }
        return 4
    }
}
