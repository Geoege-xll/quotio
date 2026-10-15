import SwiftUI

/// 仅驱动可见 UI，不轮询账号、不持有 Task。分钟刻度更新参考线，同时在重置和新鲜性
/// 截止点精确唤醒；无限惰性序列不为长时间打开的窗口预分配计时数据。
nonisolated struct QuotaPaceTimelineSchedule: TimelineSchedule {
    let points: [QuotaHistoryPoint]

    func entries(from startDate: Date, mode: TimelineScheduleMode) -> Entries {
        let deadlines = points.flatMap { point in
            [point.date.addingTimeInterval(30 * 60 + 0.01)] + (point.resetAt.map { [$0] } ?? [])
        }.filter { $0 > startDate }.sorted()
        return Entries(tick: startDate, deadlines: ArraySlice(deadlines))
    }

    struct Entries: Sequence, IteratorProtocol {
        var tick: Date
        var deadlines: ArraySlice<Date>
        mutating func next() -> Date? {
            if let deadline = deadlines.first, deadline <= tick {
                deadlines = deadlines.dropFirst()
                return deadline
            }
            let result = tick
            tick = tick.addingTimeInterval(60)
            return result
        }
    }
}

/// 额度条的细线参考刻度；仅在权威周期完整时出现，不替换原卡片／条形／环形样式配置。
/// 填充与刻度共用已用／剩余转换，避免切换显示口径后参考线方向相反。
struct QuotaPaceBar: View {
    let remaining: Double
    let pace: QuotaPace
    let displayMode: QuotaDisplayMode

    var body: some View {
        let value = displayMode.displayValue(from: remaining) / 100
        let expected = displayMode.displayValue(from: pace.expectedRemaining) / 100
        let warning = pace.projectedEmpty.map { $0 < pace.resetAt } ?? false
        GeometryReader { geometry in
            ZStack(alignment: .leading) {
                Capsule().fill(Color.secondary.opacity(0.12))
                Capsule().fill(warning ? Color.orange : Color.accentColor)
                    .frame(width: geometry.size.width * min(1, max(0, value)))
                Rectangle().fill(Color.primary)
                    .frame(width: 2, height: 10)
                    .offset(x: min(max(0, geometry.size.width * expected - 1), max(0, geometry.size.width - 2)))
            }
        }
        .frame(height: 6)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("quota.history.paceReference".localized())
        .accessibilityValue(String(format: "%.1f%%", displayMode.displayValue(from: pace.expectedRemaining)))
    }
}

/// 菜单明细与历史窗口共用的消耗提示。速率为空时不占位、不把无历史解释为零消耗。
struct QuotaPaceSummaryView: View {
    let point: QuotaHistoryPoint
    let ratePerDay: Double?
    var displayMode: QuotaDisplayMode = .remaining
    var now: Date = Date()
    @Environment(\.locale) private var locale

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            if let pace = QuotaPace(point: point, now: now) {
                QuotaPaceBar(remaining: point.value, pace: pace, displayMode: displayMode)
                if let empty = pace.projectedEmpty, empty < pace.resetAt {
                    Text(String(format: "quota.history.emptyEstimate".localized(),
                        empty.formatted(.dateTime.month(.abbreviated).day().hour().minute().locale(locale))))
                        .foregroundStyle(.orange)
                } else { Text("quota.history.onPace".localized()).foregroundStyle(.secondary) }
            } else if let ratePerDay {
                let value = point.kind == .percentage ? String(format: "%.1f%%", ratePerDay)
                    : point.unit?.format(ratePerDay) ?? String(format: "%.1f", ratePerDay)
                Text(String(format: "quota.history.dailyRate".localized(), value)).foregroundStyle(.secondary)
            }
        }.font(.caption2)
    }
}
