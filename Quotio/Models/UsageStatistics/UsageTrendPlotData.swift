import Foundation

/// 折线绘制使用有界采样，完整日汇总仍供统计、悬停读数和逐日明细使用。
/// 每个分段保留最低与最高的真实日值，避免简单等距抽点漏掉短时高峰或虚构平均用量。
nonisolated enum UsageTrendPlotData {
    static func sampled(_ days: [UsageStatisticsDay], maximumPoints: Int = 240) -> [UsageStatisticsDay] {
        precondition(maximumPoints >= 4)
        guard days.count > maximumPoints else { return days }
        let segmentCount = (maximumPoints - 2) / 2
        let interiorCount = days.count - 2
        var result = [days[0]]
        result.reserveCapacity(maximumPoints)
        for segment in 0..<segmentCount {
            let start = 1 + interiorCount * segment / segmentCount
            let end = 1 + interiorCount * (segment + 1) / segmentCount
            let indices = start..<end
            guard let lowest = indices.min(by: { days[$0].totals.totalTokens < days[$1].totals.totalTokens }),
                  let highest = indices.max(by: { days[$0].totals.totalTokens < days[$1].totals.totalTokens }) else { continue }
            // 同一日可能同时是极值，只加入一次；按原始日期顺序输出，避免折线反向连接。
            result.append(days[min(lowest, highest)])
            if lowest != highest { result.append(days[max(lowest, highest)]) }
        }
        result.append(days[days.count - 1])
        return result
    }

    /// 输入为展示层已排好序的真实日期。二分定位完整明细中的最近一天，
    /// 同一天内的鼠标移动共用同一个日期身份，不再每个像素都发布一个新的浮点时间。
    static func nearest(to date: Date, in days: [UsageStatisticsDay]) -> UsageStatisticsDay? {
        guard !days.isEmpty else { return nil }
        var lower = 0
        var upper = days.count
        while lower < upper {
            let middle = lower + (upper - lower) / 2
            if days[middle].day < date { lower = middle + 1 }
            else { upper = middle }
        }
        if lower == 0 { return days[0] }
        if lower == days.count { return days[days.count - 1] }
        let before = days[lower - 1]
        let after = days[lower]
        return date.timeIntervalSince(before.day) <= after.day.timeIntervalSince(date) ? before : after
    }
}
