//
//  MenuAnalyticsTrendView.swift
//  Quotio
//

import AppKit
import SwiftUI

/// 菜单栏原有趋势模式、选择器及热力图。
/// 只开放分析明细需要的模式、选择器和图表入口；原聚合算法与桶模型继续私有，悬停状态仍在原图表类型内。
enum AnalyticsTrendMode: String, CaseIterable, Identifiable {
    case daily
    case weekly
    case cumulative

    var id: String { rawValue }

    var title: String {
        switch self {
        case .daily: "Daily"
        case .weekly: "Weekly"
        case .cumulative: "Cumulative"
        }
    }
}

struct AnalyticsTrendModePicker: View {
    @Binding var selection: AnalyticsTrendMode

    var body: some View {
        HStack(spacing: 8) {
            ForEach(AnalyticsTrendMode.allCases) { mode in
                Button {
                    selection = mode
                } label: {
                    Text(mode.title)
                        .font(.system(size: 10, weight: .medium, design: .rounded))
                        .foregroundStyle(selection == mode ? .primary : .tertiary)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }
        }
    }
}

private enum AnalyticsTrendSeries {
    typealias ParsedPoint = (date: Date, point: QuotaAnalyticsPoint)

    static func dailyPoints(from points: [QuotaAnalyticsPoint]) -> [QuotaAnalyticsPoint] {
        parsedPoints(from: points).map { item in
            QuotaAnalyticsPoint(
                date: dayLabel(for: item.date),
                value: item.point.value,
                label: "on \(shortDateLabel(for: item.date))",
                valueLabel: item.point.valueLabel.isEmpty ? tokenLabel(item.point.value) : item.point.valueLabel
            )
        }
    }

    static func weeklyBuckets(from points: [QuotaAnalyticsPoint], mode: AnalyticsTrendMode) -> [AnalyticsTrendBucket] {
        let parsed = parsedPoints(from: points)
        let grouped = Dictionary(grouping: parsed) { item in
            startOfWeek(containing: item.date)
        }
        switch mode {
        case .daily, .weekly:
            return grouped.keys.sorted().map { weekStart in
                let weeklyValue = grouped[weekStart, default: []].reduce(0) { total, item in
                    total + item.point.value
                }
                return AnalyticsTrendBucket(
                    weekStart: weekStart,
                    value: weeklyValue,
                    valueLabel: tokenLabel(weeklyValue),
                    tooltipLabel: "on week of \(longDateLabel(for: weekStart))"
                )
            }
        case .cumulative:
            let sortedWeeks = grouped.keys.sorted()
            guard let first = sortedWeeks.first, let last = sortedWeeks.last else {
                return []
            }

            var buckets: [AnalyticsTrendBucket] = []
            var runningTotal = 0.0
            var weekStart = first

            while weekStart <= last {
                runningTotal += grouped[weekStart, default: []].reduce(0) { total, item in
                    total + item.point.value
                }
                buckets.append(AnalyticsTrendBucket(
                    weekStart: weekStart,
                    value: runningTotal,
                    valueLabel: tokenLabel(runningTotal),
                    tooltipLabel: "through week of \(longDateLabel(for: weekStart))"
                ))

                guard let nextWeek = calendar.date(byAdding: .day, value: 7, to: weekStart) else {
                    break
                }
                weekStart = nextWeek
            }

            return buckets
        }
    }

    static var calendar: Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.firstWeekday = 1
        return calendar
    }

    static func dayLabel(for date: Date) -> String {
        let components = calendar.dateComponents([.year, .month, .day], from: date)
        guard let year = components.year, let month = components.month, let day = components.day else {
            return "Unknown"
        }
        return String(format: "%04d-%02d-%02d", year, month, day)
    }

    private static func parsedPoints(from points: [QuotaAnalyticsPoint]) -> [ParsedPoint] {
        points.compactMap { point in
            guard let date = date(from: point.date) else { return nil }
            return (calendar.startOfDay(for: date), point)
        }
        .sorted { $0.date < $1.date }
    }

    private static func startOfWeek(containing date: Date) -> Date {
        let components = calendar.dateComponents([.yearForWeekOfYear, .weekOfYear], from: date)
        return calendar.date(from: components).map { calendar.startOfDay(for: $0) } ?? date
    }

    private static func date(from string: String) -> Date? {
        let day = String(string.prefix(10))
        let parts = day.split(separator: "-").compactMap { Int($0) }
        guard parts.count == 3 else { return nil }
        return calendar.date(from: DateComponents(year: parts[0], month: parts[1], day: parts[2]))
    }

    private static func shortDateLabel(for date: Date) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "MMM d"
        return formatter.string(from: date)
    }

    private static func longDateLabel(for date: Date) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "MMM d, yyyy"
        return formatter.string(from: date)
    }

    private static func tokenLabel(_ value: Double) -> String {
        let absoluteValue = abs(value)
        if absoluteValue >= 1_000_000_000 {
            return "\(compactNumber(value / 1_000_000_000))B tokens"
        }
        if absoluteValue >= 1_000_000 {
            return "\(compactNumber(value / 1_000_000))M tokens"
        }
        if absoluteValue >= 1_000 {
            return "\(compactNumber(value / 1_000))K tokens"
        }
        return "\(Int(value.rounded())) tokens"
    }

    private static func compactNumber(_ value: Double) -> String {
        let rounded = (value * 10).rounded() / 10
        if rounded.truncatingRemainder(dividingBy: 1) == 0 {
            return "\(Int(rounded))"
        }
        return String(format: "%.1f", rounded)
    }
}

private struct AnalyticsTrendBucket: Identifiable {
    var id: String { AnalyticsTrendSeries.dayLabel(for: weekStart) }
    let weekStart: Date
    let value: Double
    let valueLabel: String
    let tooltipLabel: String
}

struct UsageTrendHeatmap: View {
    let points: [QuotaAnalyticsPoint]
    let mode: AnalyticsTrendMode

    @State private var hoveredCellID: String?

    private let cellSize: CGFloat = 9
    private let spacing: CGFloat = 2.4

    private var calendar: Calendar {
        AnalyticsTrendSeries.calendar
    }

    private var parsedPoints: [(date: Date, point: QuotaAnalyticsPoint)] {
        AnalyticsTrendSeries.dailyPoints(from: points).compactMap { point in
            guard let date = Self.date(from: point.date, calendar: calendar) else { return nil }
            return (calendar.startOfDay(for: date), point)
        }
        .sorted { $0.date < $1.date }
    }

    private var heatmapData: HeatmapData {
        switch mode {
        case .daily:
            dailyHeatmapData()
        case .weekly, .cumulative:
            weeklyHeatmapData()
        }
    }

    private func dailyHeatmapData() -> HeatmapData {
        let parsed = parsedPoints
        guard let last = parsed.last?.date else {
            return HeatmapData(weeks: [], monthLabels: [], width: 0)
        }

        let pointByDate = parsed.reduce(into: [Date: QuotaAnalyticsPoint]()) { result, item in
            result[item.date] = item.point
        }
        let maxValue = max(parsed.map(\.point.value).max() ?? 0, 1)
        let first = displayStartDate(endingAt: last)
        let start = startOfWeek(containing: first)
        let days = max(calendar.dateComponents([.day], from: start, to: last).day ?? 0, 0)
        let weekCount = min((days / 7) + 1, 54)

        let weeks = (0..<weekCount).map { weekIndex in
            let cells = (0..<7).map { weekdayIndex -> HeatmapCell in
                let dayOffset = weekIndex * 7 + weekdayIndex
                let date = calendar.date(byAdding: .day, value: dayOffset, to: start) ?? start
                let point = pointByDate[date]
                let intensity = point.map { point in
                    point.value <= 0 ? 0 : max(0.18, min(point.value / maxValue, 1))
                } ?? 0
                let isInRange = date >= first && date <= last
                return HeatmapCell(
                    id: "\(weekIndex)-\(weekdayIndex)",
                    date: date,
                    point: point,
                    intensity: intensity,
                    isInRange: isInRange
                )
            }
            return HeatmapWeek(id: weekIndex, cells: cells)
        }

        let labels = monthLabels(from: start, first: first, last: last, weekCount: weekCount)
        let width = CGFloat(weekCount) * cellSize + CGFloat(max(weekCount - 1, 0)) * spacing
        return HeatmapData(weeks: weeks, monthLabels: labels, width: width)
    }

    private func weeklyHeatmapData() -> HeatmapData {
        let buckets = AnalyticsTrendSeries.weeklyBuckets(from: points, mode: mode)
        guard let last = buckets.last?.weekStart else {
            return HeatmapData(weeks: [], monthLabels: [], width: 0)
        }

        let bucketByWeek = buckets.reduce(into: [Date: AnalyticsTrendBucket]()) { result, bucket in
            result[bucket.weekStart] = bucket
        }
        let maxValue = max(buckets.map(\.value).max() ?? 0, 1)
        let first = startOfWeek(containing: displayStartDate(endingAt: last))
        let days = max(calendar.dateComponents([.day], from: first, to: last).day ?? 0, 0)
        let weekCount = min((days / 7) + 1, 54)

        let weeks = (0..<weekCount).map { weekIndex in
            let weekStart = calendar.date(byAdding: .day, value: weekIndex * 7, to: first) ?? first
            let bucket = bucketByWeek[weekStart]
            let normalizedValue = bucket.map { $0.value <= 0 ? 0 : max(0.14, min($0.value / maxValue, 1)) } ?? 0
            let filledRows = normalizedValue <= 0 ? 0 : max(1, min(Int((normalizedValue * 7).rounded(.up)), 7))

            let cells = (0..<7).map { rowIndex -> HeatmapCell in
                let isFilled = rowIndex >= 7 - filledRows
                let point = bucket.map { bucket -> QuotaAnalyticsPoint in
                    QuotaAnalyticsPoint(
                        date: AnalyticsTrendSeries.dayLabel(for: weekStart),
                        value: bucket.value,
                        label: bucket.tooltipLabel,
                        valueLabel: bucket.valueLabel
                    )
                }

                return HeatmapCell(
                    id: "\(weekIndex)-\(rowIndex)",
                    date: weekStart,
                    point: isFilled ? point : nil,
                    intensity: isFilled ? normalizedValue : 0,
                    isInRange: true
                )
            }
            return HeatmapWeek(id: weekIndex, cells: cells)
        }

        let labels = monthLabels(from: first, first: first, last: last, weekCount: weekCount)
        let width = CGFloat(weekCount) * cellSize + CGFloat(max(weekCount - 1, 0)) * spacing
        return HeatmapData(weeks: weeks, monthLabels: labels, width: width)
    }

    var body: some View {
        let data = heatmapData
        // 只保存悬停位置，读数始终来自本轮数据。原生菜单会原位刷新且鼠标可能不动，
        // 若把文案另存为 State，onHover 不再触发时会继续显示旧值，甚至显示已删除日期。
        let hoveredCell = data.weeks.lazy.flatMap(\.cells).first { $0.id == hoveredCellID }
        let hoveredText = hoveredCell.flatMap { cell in
            cell.point.map { point in
                point.label.isEmpty
                    ? "\(point.valueLabel) on \(Self.shortDateLabel(for: cell.date))"
                    : "\(point.valueLabel) \(point.label)"
            }
        }

        ZStack(alignment: .topTrailing) {
            VStack(alignment: .leading, spacing: 6) {
                HStack(spacing: 0) {
                    ForEach(data.monthLabels) { label in
                        Text(label.title)
                            .font(.system(size: 9, weight: .medium, design: .rounded))
                            .foregroundStyle(.tertiary)
                            .frame(width: monthLabelWidth(for: label, in: data), alignment: .leading)
                    }
                }
                .frame(width: data.width, height: 12, alignment: .leading)

                HStack(alignment: .top, spacing: spacing) {
                    ForEach(data.weeks) { week in
                        VStack(spacing: spacing) {
                            ForEach(week.cells) { cell in
                                heatmapCell(cell)
                            }
                        }
                    }
                }
                .frame(width: data.width, alignment: .leading)
            }

            if let hoveredText {
                Text(hoveredText)
                    .font(.system(size: 10, weight: .semibold, design: .rounded))
                    .foregroundStyle(.primary)
                    .lineLimit(1)
                    .padding(.horizontal, 10)
                    .padding(.vertical, 6)
                    .background(.regularMaterial, in: Capsule())
                    .overlay(
                        Capsule()
                            .stroke(Color.primary.opacity(0.08), lineWidth: 1)
                    )
                    .shadow(color: .black.opacity(0.16), radius: 8, y: 3)
                    .offset(y: 18)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.vertical, 2)
    }

    private func heatmapCell(_ cell: HeatmapCell) -> some View {
        RoundedRectangle(cornerRadius: 2.4, style: .continuous)
            .fill(fillColor(for: cell))
            .frame(width: cellSize, height: cellSize)
            .opacity(cell.isInRange ? 1 : 0)
            .overlay {
                if hoveredCellID == cell.id, cell.point != nil {
                    RoundedRectangle(cornerRadius: 2.4, style: .continuous)
                        .stroke(Color.primary.opacity(0.18), lineWidth: 1)
                }
            }
            .onHover { hovering in
                updateHover(hovering, cell: cell)
            }
    }

    private func fillColor(for cell: HeatmapCell) -> Color {
        guard cell.intensity > 0 else {
            return Color.primary.opacity(0.06)
        }
        return Color.accentColor.opacity(0.16 + cell.intensity * 0.78)
    }

    private func updateHover(_ hovering: Bool, cell: HeatmapCell) {
        guard cell.point != nil else {
            if !hovering, hoveredCellID == cell.id {
                hoveredCellID = nil
            }
            return
        }

        if hovering {
            hoveredCellID = cell.id
        } else if hoveredCellID == cell.id {
            hoveredCellID = nil
        }
    }

    private func monthLabelWidth(for label: MonthLabel, in data: HeatmapData) -> CGFloat {
        guard let index = data.monthLabels.firstIndex(where: { $0.id == label.id }) else {
            return 0
        }
        let nextColumn = data.monthLabels.dropFirst(index + 1).first?.column ?? data.weeks.count
        let columns = max(nextColumn - label.column, 1)
        return CGFloat(columns) * cellSize + CGFloat(max(columns - 1, 0)) * spacing
    }

    private func startOfWeek(containing date: Date) -> Date {
        let components = calendar.dateComponents([.yearForWeekOfYear, .weekOfYear], from: date)
        return calendar.date(from: components).map { calendar.startOfDay(for: $0) } ?? date
    }

    private func displayStartDate(endingAt date: Date) -> Date {
        calendar.date(byAdding: .day, value: -370, to: date)
            .map { calendar.startOfDay(for: $0) } ?? date
    }

    private func monthLabels(from start: Date, first: Date, last: Date, weekCount: Int) -> [MonthLabel] {
        var labels: [MonthLabel] = []
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "MMM"

        var components = calendar.dateComponents([.year, .month], from: first)
        components.day = 1
        var monthStart = calendar.date(from: components) ?? first
        if monthStart < first {
            monthStart = calendar.date(byAdding: .month, value: 1, to: monthStart) ?? first
        }

        while monthStart <= last {
            let column = max(calendar.dateComponents([.day], from: start, to: monthStart).day ?? 0, 0) / 7
            if column < weekCount {
                labels.append(MonthLabel(
                    id: AnalyticsTrendSeries.dayLabel(for: monthStart),
                    title: formatter.string(from: monthStart),
                    column: column
                ))
            }
            guard let nextMonth = calendar.date(byAdding: .month, value: 1, to: monthStart) else { break }
            monthStart = nextMonth
        }
        return labels
    }

    private static func date(from string: String, calendar: Calendar) -> Date? {
        let day = String(string.prefix(10))
        let parts = day.split(separator: "-").compactMap { Int($0) }
        guard parts.count == 3 else { return nil }
        return calendar.date(from: DateComponents(year: parts[0], month: parts[1], day: parts[2]))
    }

    private static func shortDateLabel(for date: Date) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "MMM d"
        return formatter.string(from: date)
    }

    private struct HeatmapData {
        let weeks: [HeatmapWeek]
        let monthLabels: [MonthLabel]
        let width: CGFloat
    }

    private struct HeatmapWeek: Identifiable {
        let id: Int
        let cells: [HeatmapCell]
    }

    private struct HeatmapCell: Identifiable {
        let id: String
        let date: Date
        let point: QuotaAnalyticsPoint?
        let intensity: Double
        let isInRange: Bool
    }

    private struct MonthLabel: Identifiable {
        let id: String
        let title: String
        let column: Int
    }
}
