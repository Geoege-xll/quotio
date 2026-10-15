import Foundation

/// 两份账本只在展示层按本地日期对齐。每项保留自己的数值与可用性，
/// 不将工具次数计入 Token，也不因一方缺失而隐藏另一方的数据。
nonisolated struct ClientAnalyticsDailyTrendData: Equatable {
    struct Day: Identifiable, Equatable {
        let date: Date
        let tokens: Int?
        let tools: Int?
        // 连续时间轴的柱宽取相邻本地日间距，夏令时跨日可以为 23／25 小时。
        let barStart: Date
        let barEnd: Date
        var id: Date { date }
    }

    enum Metric: String {
        case tokens, tools
        var titleKey: String { "clientAnalytics.trend." + rawValue }
        func value(_ day: Day) -> Int? { self == .tokens ? day.tokens : day.tools }
    }

    let days: [Day]
    let domain: ClosedRange<Date>
    let axisDates: [Date]
    let spansYears: Bool
    let tokensAvailable: Bool
    let toolsAvailable: Bool

    init(tokenDays: [UsageStatisticsDay], tokensAvailable: Bool,
         calls: [CallAnalyticsTrendPoint], toolsAvailable: Bool,
         lowerDay: String?, upperDay: String?, now: Date, calendar: Calendar = .current) {
        self.tokensAvailable = tokensAvailable
        self.toolsAvailable = toolsAvailable
        // 调用账本的 yyyy-MM-dd 是公历本地日期。不能按 UTC 零点解析，
        // 否则亚洲时区／夏令时切换后会与 Token 日桶错位。
        let parser = DateFormatter()
        parser.locale = Locale(identifier: "en_US_POSIX")
        parser.calendar = Calendar(identifier: .gregorian)
        parser.timeZone = calendar.timeZone
        parser.dateFormat = "yyyy-MM-dd"
        parser.isLenient = false
        let tokenValues = Dictionary(grouping: tokenDays, by: { calendar.startOfDay(for: $0.day) })
            .mapValues { $0.reduce(0) { $0 + $1.totals.totalTokens } }
        let callValues = calls.reduce(into: [Date: Int]()) { result, point in
            guard let date = parser.date(from: point.day) else { return }
            result[calendar.startOfDay(for: date), default: 0] += point.count
        }
        let observedDates = Array(tokenValues.keys) + Array(callValues.keys)
        let first = lowerDay.flatMap { parser.date(from: $0) }
            ?? observedDates.min() ?? calendar.startOfDay(for: now)
        let last = upperDay.flatMap { parser.date(from: $0) }
            ?? observedDates.max() ?? first
        let start = calendar.startOfDay(for: min(first, last))
        let end = calendar.startOfDay(for: max(first, last))
        spansYears = calendar.component(.year, from: start) != calendar.component(.year, from: end)
        var rows: [Day] = []
        var date = start
        while date <= end {
            guard let previous = calendar.date(byAdding: .day, value: -1, to: date),
                  let next = calendar.date(byAdding: .day, value: 1, to: date), next > date else { break }
            // 两侧使用相同半宽。夏令时两侧日长不同，分别取宽会使柱体中心偏离该日零点。
            let halfWidth = min(date.timeIntervalSince(previous), next.timeIntervalSince(date)) * 0.35
            rows.append(Day(date: date,
                // 可用账本在某天没有事件时为零；整个来源不可用时仍是未知。
                // 补齐日期只影响绘图与明细，不回写账本，也不修改顶部总量。
                tokens: tokensAvailable ? tokenValues[date, default: 0] : nil,
                tools: toolsAvailable ? callValues[date, default: 0] : nil,
                barStart: date.addingTimeInterval(-halfWidth),
                barEnd: date.addingTimeInterval(halfWidth)))
            date = next
        }
        days = rows
        // 首尾各留半个本地日，单日折线点和柱子也有合法、相同的横向范围。
        let previous = calendar.date(byAdding: .day, value: -1, to: start) ?? start
        let next = calendar.date(byAdding: .day, value: 1, to: end) ?? end
        let domainStart = start.addingTimeInterval(-start.timeIntervalSince(previous) / 2)
        let domainEnd = end.addingTimeInterval(next.timeIntervalSince(end) / 2)
        domain = domainStart...domainEnd
        // 两图使用同一批日期刻度，最多五个；不让 Charts 分别自动选出不同日期。
        let count = min(5, rows.count)
        axisDates = (0..<count).map { index in
            rows[count == 1 ? 0 : index * (rows.count - 1) / (count - 1)].date
        }
    }

    func available(_ metric: Metric) -> Bool { metric == .tokens ? tokensAvailable : toolsAvailable }
    func maximum(_ metric: Metric) -> Int { max(1, days.compactMap(metric.value).max() ?? 0) }
    func plottedDays(_ metric: Metric) -> [Day] {
        UsageTrendPlotData.sampled(days, value: { metric.value($0) ?? 0 })
    }
    func nearest(to date: Date) -> Day? {
        UsageTrendPlotData.nearest(to: date, in: days, day: { $0.date })
    }
}
