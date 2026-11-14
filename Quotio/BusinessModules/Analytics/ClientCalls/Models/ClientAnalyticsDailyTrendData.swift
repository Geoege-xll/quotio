import Foundation

/// 客户端工具调用每日趋势模型：按本地公历日对齐调用账本，
/// 已按用户要求彻底移除本地会话 Token 趋势数据，仅保留工具调用次数及其可用性。
nonisolated struct ClientAnalyticsDailyTrendData: Equatable {
    struct Day: Identifiable, Equatable {
        let date: Date
        let tools: Int?
        // 连续时间轴的柱宽取相邻本地日间距，夏令时跨日可以为 23／25 小时。
        let barStart: Date
        let barEnd: Date
        var id: Date { date }
    }

    enum Metric: String {
        case tools
        var titleKey: String { "clientAnalytics.trend." + rawValue }
        func value(_ day: Day) -> Int? { day.tools }
    }

    let days: [Day]
    let domain: ClosedRange<Date>
    let axisDates: [Date]
    let spansYears: Bool
    let toolsAvailable: Bool

    init(calls: [CallAnalyticsTrendPoint], toolsAvailable: Bool,
         lowerDay: String?, upperDay: String?, now: Date, calendar: Calendar = .current) {
        self.toolsAvailable = toolsAvailable
        // 调用账本的 yyyy-MM-dd 是公历本地日期。不能按 UTC 零点解析，
        // 否则亚洲时区／夏令时切换后会与本地日历错位。
        let parser = DateFormatter()
        parser.locale = Locale(identifier: "en_US_POSIX")
        parser.calendar = Calendar(identifier: .gregorian)
        parser.timeZone = calendar.timeZone
        parser.dateFormat = "yyyy-MM-dd"
        parser.isLenient = false
        let callValues = calls.reduce(into: [Date: Int]()) { result, point in
            guard let date = parser.date(from: point.day) else { return }
            result[calendar.startOfDay(for: date), default: 0] += point.count
        }
        let observedDates = Array(callValues.keys)
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
                tools: toolsAvailable ? callValues[date, default: 0] : nil,
                barStart: date.addingTimeInterval(-halfWidth),
                barEnd: date.addingTimeInterval(halfWidth)))
            date = next
        }
        days = rows
        // 首尾各留半个本地日，单日柱子也有合法、对称的横向范围。
        let previous = calendar.date(byAdding: .day, value: -1, to: start) ?? start
        let next = calendar.date(byAdding: .day, value: 1, to: end) ?? end
        let domainStart = start.addingTimeInterval(-start.timeIntervalSince(previous) / 2)
        let domainEnd = end.addingTimeInterval(next.timeIntervalSince(end) / 2)
        domain = domainStart...domainEnd
        // 固定最多五个日期刻度，保证长短区间下横轴标签均匀清晰。
        let count = min(5, rows.count)
        axisDates = (0..<count).map { index in
            rows[count == 1 ? 0 : index * (rows.count - 1) / (count - 1)].date
        }
    }

    func available(_ metric: Metric = .tools) -> Bool { toolsAvailable }
    func maximum(_ metric: Metric = .tools) -> Int { max(1, days.compactMap(metric.value).max() ?? 0) }
    func plottedDays(_ metric: Metric = .tools) -> [Day] {
        UsageTrendPlotData.sampled(days, value: { metric.value($0) ?? 0 })
    }
    func nearest(to date: Date) -> Day? {
        UsageTrendPlotData.nearest(to: date, in: days, day: { $0.date })
    }
}
