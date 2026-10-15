import Foundation

/// 热力图固定展示最近 52 周，周一在第一行。所有日期用 Calendar 递增，避免夏令时错位。
/// 图表窗口独立于摘要时间筛选，与参考页面的全年活跃视图一致；提供商和模型筛选仍生效。
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

    init(buckets: [UsageBucket], now: Date, firstCollectedAt: Date?, calendar: Calendar = .current) {
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
                return Day(date: date, totals: presentation.totals, models: presentation.models,
                           isFuture: date > today, isBeforeCollection: entries.isEmpty && firstDay.map { date < $0 } == true)
            }
            weeks.append(Week(days: days))
        }
        self.weeks = weeks
        let visible = weeks.flatMap(\.days).filter { !$0.isFuture }
        let positive = visible.map(\.totals.totalTokens).filter { $0 > 0 }.sorted()
        thresholds = positive.isEmpty ? [] : [positive[(positive.count - 1) / 4], positive[(positive.count - 1) / 2], positive[(positive.count - 1) * 3 / 4]]
        activeDays = positive.count
        peak = visible.filter { $0.totals.totalTokens > 0 }.max { $0.totals.totalTokens < $1.totals.totalTokens }
        totals = UsageTotals(buckets: buckets.filter { $0.day >= start && $0.day <= today })
    }

    /// 使用正用量的四分位色阶，避免少数大请求令其余活跃日全部变成近乎不可见。
    func intensity(_ tokens: Int) -> Int {
        guard tokens > 0, thresholds.count == 3 else { return 0 }
        if tokens <= thresholds[0] { return 1 }
        if tokens <= thresholds[1] { return 2 }
        if tokens <= thresholds[2] { return 3 }
        return 4
    }
}
