import Foundation

/// 热力图固定展示最近 52 周，周一在第一行。所有日期用 Calendar 递增，避免夏令时错位。
/// 图表窗口独立于摘要时间筛选，与全年活跃视图一致；非时间筛选（提供商、模型、来源、API Key、状态）仍生效，
/// 并支持按 Tokens 或请求数口径同步计算四分位色阶、活跃天数、峰值日与单日模型排行。
nonisolated struct UsageHeatmapPresentation {
    struct Day: Identifiable {
        let date: Date
        let totals: UsageTotals
        let models: [UsageStatisticsModel]
        let isFuture: Bool
        let isBeforeCollection: Bool
        var id: Date { date }
    }
    struct Week: Identifiable {
        let days: [Day]
        var id: Date { days[0].date }
    }
    let weeks: [Week]
    let thresholds: [Int]
    let totals: UsageTotals
    let activeDays: Int
    let peak: Day?
    let metric: CPAUsageChartMetric

    /// 计算最近 52 周周一开周的起始本地日，确保 SQL 查询、历史合并与网格构造使用同一时间起点。
    static func windowStart(now: Date = Date(), anchorEnd: Date? = nil, calendar: Calendar = .current) -> Date {
        let anchor = calendar.startOfDay(for: max(now, anchorEnd ?? .distantPast))
        let mondayOffset = (calendar.component(.weekday, from: anchor) + 5) % 7
        return calendar.date(byAdding: .day, value: -mondayOffset - 51 * 7, to: anchor) ?? anchor
    }

    init(buckets: [UsageBucket], now: Date, firstCollectedAt: Date?,
         metric: CPAUsageChartMetric = .tokens, calendar: Calendar = .current) {
        self.metric = metric
        let today = calendar.startOfDay(for: now)
        let mondayOffset = (calendar.component(.weekday, from: today) + 5) % 7
        let start = calendar.date(byAdding: .day, value: -mondayOffset - 51 * 7, to: today) ?? today
        let firstDay = firstCollectedAt.map { calendar.startOfDay(for: $0) }
        let grouped = Dictionary(grouping: buckets, by: { calendar.startOfDay(for: $0.day) })
        var weeks: [Week] = []
        for week in 0..<52 {
            let days = (0..<7).map { row in
                let date = calendar.date(byAdding: .day, value: week * 7 + row, to: start) ?? start
                let entries = grouped[date] ?? []
                let presentation = UsageStatisticsPresentation(buckets: entries, interval: nil, provider: nil, model: nil)
                // 请求数口径按当日模型请求量降序展示，Tokens 口径沿用总 Token 降序。
                let sortedModels = metric == .tokens
                    ? presentation.models
                    : presentation.models.sorted {
                        if $0.totals.requests != $1.totals.requests { return $0.totals.requests > $1.totals.requests }
                        if $0.totals.totalTokens != $1.totals.totalTokens { return $0.totals.totalTokens > $1.totals.totalTokens }
                        return $0.id < $1.id
                    }
                return Day(date: date, totals: presentation.totals, models: sortedModels,
                           isFuture: date > today, isBeforeCollection: entries.isEmpty && firstDay.map { date < $0 } == true)
            }
            weeks.append(Week(days: days))
        }
        self.weeks = weeks
        let visible = weeks.flatMap(\.days).filter { !$0.isFuture }
        let metricValue: (Day) -> Int = { metric == .tokens ? $0.totals.totalTokens : $0.totals.requests }
        let positive = visible.map(metricValue).filter { $0 > 0 }.sorted()
        thresholds = positive.isEmpty ? [] : [positive[(positive.count - 1) / 4], positive[(positive.count - 1) / 2], positive[(positive.count - 1) * 3 / 4]]
        activeDays = positive.count
        peak = visible.filter { metricValue($0) > 0 }.max { metricValue($0) < metricValue($1) }
        totals = UsageTotals(buckets: buckets.filter { calendar.startOfDay(for: $0.day) >= start && calendar.startOfDay(for: $0.day) <= today })
    }

    func value(for totals: UsageTotals) -> Int {
        metric == .tokens ? totals.totalTokens : totals.requests
    }

    func value(for model: UsageStatisticsModel) -> Int {
        value(for: model.totals)
    }

    /// 使用正用量的四分位色阶，避免少数峰值日令其余活跃日全部变成近乎不可见。
    func intensity(_ value: Int) -> Int {
        guard value > 0, thresholds.count == 3 else { return 0 }
        if value <= thresholds[0] { return 1 }
        if value <= thresholds[1] { return 2 }
        if value <= thresholds[2] { return 3 }
        return 4
    }
}
