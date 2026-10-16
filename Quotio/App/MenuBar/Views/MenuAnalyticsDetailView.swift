//
//  MenuAnalyticsDetailView.swift
//  Quotio
//

import AppKit
import SwiftUI

/// 菜单栏账号分析明细与额度汇总展示。
/// 趋势模式的 @State 仍由原 AnalyticsDetailSection 持有，按原绑定传入趋势组件；局部指标与额度徽章保留私有。
struct AnalyticsDetailSection: View {
    let analytics: QuotaAnalytics

    @State private var trendMode: AnalyticsTrendMode = .daily

    private static let primaryMetricRowIDs = [
        "codex-lifetime-tokens",
        "codex-peak-daily",
        "codex-longest-task",
        "codex-current-streak",
        "codex-longest-streak"
    ]

    private static let usageMetricRowIDs = [
        "codex-extra-usage",
        "today",
        "yesterday",
        "last-30-days"
    ]

    private static let hiddenRowIDs = Set(primaryMetricRowIDs + usageMetricRowIDs)
    private static let resetCreditsSummaryID = "codex-rate-limit-resets"
    private static let resetCreditRowPrefix = "codex-rate-limit-reset-"

    private var metricRows: [QuotaAnalyticsRow] {
        metricRows(for: Self.primaryMetricRowIDs)
    }

    private var usageRows: [QuotaAnalyticsRow] {
        metricRows(for: Self.usageMetricRowIDs)
    }

    private var shouldShowNote: Bool {
        metricRows.isEmpty && usageRows.isEmpty && resetCreditsSummary == nil
    }

    private func metricRows(for ids: [String]) -> [QuotaAnalyticsRow] {
        let rowsByID = analytics.rows.reduce(into: [String: QuotaAnalyticsRow]()) { result, row in
            result[row.id] = result[row.id] ?? row
        }
        return ids.compactMap { rowsByID[$0] }
    }

    private var detailRows: [QuotaAnalyticsRow] {
        analytics.rows.filter {
            !Self.hiddenRowIDs.contains($0.id)
                && $0.id != Self.resetCreditsSummaryID
                && !$0.id.hasPrefix(Self.resetCreditRowPrefix)
        }
    }

    private var resetCreditsSummary: QuotaAnalyticsRow? {
        analytics.rows.first { $0.id == Self.resetCreditsSummaryID }
    }

    private var resetCreditRows: [QuotaAnalyticsRow] {
        analytics.rows.filter { $0.id.hasPrefix(Self.resetCreditRowPrefix) }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 11) {
            if !metricRows.isEmpty {
                AnalyticsMetricStripView(rows: metricRows)
            }

            if !usageRows.isEmpty {
                AnalyticsMetricStripView(rows: usageRows)
            }

            if let resetCreditsSummary {
                ResetCreditsInventoryView(summary: resetCreditsSummary, credits: resetCreditRows)
            }

            VStack(alignment: .leading, spacing: 8) {
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    Text("Usage Trend")
                        .font(.system(size: 11, weight: .semibold, design: .rounded))
                        .foregroundStyle(.primary)

                    Spacer()

                    if analytics.trend.isEmpty {
                        Text("No data")
                            .font(.system(size: 10, weight: .medium, design: .rounded))
                            .foregroundStyle(.secondary)
                    } else {
                        AnalyticsTrendModePicker(selection: $trendMode)
                    }
                }

                if !analytics.trend.isEmpty {
                    UsageTrendHeatmap(points: analytics.trend, mode: trendMode)
                        .id(trendMode)
                }
            }

            ForEach(detailRows) { row in
                AnalyticsRowView(row: row)
            }

            if shouldShowNote, let note = analytics.note, !note.isEmpty {
                Text(note)
                    .font(.system(size: 9, design: .rounded))
                    .foregroundStyle(.tertiary)
                    .lineLimit(2)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(10)
    }
}

private struct ResetCreditsInventoryView: View {
    let summary: QuotaAnalyticsRow
    let credits: [QuotaAnalyticsRow]

    private var countLabel: String {
        let count = summary.value.split(separator: " ").first.map(String.init) ?? "0"
        return "\(count) resets available"
    }

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: "gift")
                .font(.system(size: 14, weight: .semibold))
                .foregroundStyle(Color.blue)

            Text(countLabel)
                .font(.system(size: 13, weight: .semibold, design: .monospaced))
                .foregroundStyle(.primary)
                .lineLimit(1)
                .minimumScaleFactor(0.85)

            Spacer(minLength: 12)

            // 库存数量由接口决定，不能把全部标签放进无边界 HStack：标签会被挤到只剩
            // 胶囊背景，并把整个原生菜单内容撑出固定宽度。只在库存段内横向滚动，
            // 每张券保留自然宽度、原次序及到期提示，其余分析与账号布局不变。
            ScrollView(.horizontal) {
                HStack(spacing: 6) {
                    ForEach(Array(credits.enumerated()), id: \.element.id) { index, credit in
                        ResetCreditChip(
                            label: compactRelativeLabel(credit.value),
                            tooltip: creditTooltip(credit),
                            isNext: index == 0
                        )
                        .fixedSize()
                    }
                }
            }
            .frame(height: 32)
            .scrollBounceBehavior(.basedOnSize, axes: .horizontal)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 7)
        .background(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .fill(Color.primary.opacity(0.025))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .stroke(.separator.opacity(0.45), lineWidth: 1)
        )
    }

    private func compactRelativeLabel(_ value: String) -> String {
        let lowercased = value.lowercased()
        let parts = lowercased.split(separator: " ")
        guard parts.count >= 3, parts.first == "in", let number = parts.dropFirst().first else {
            return value.isEmpty ? "∞" : value
        }

        let unit = parts.dropFirst(2).first ?? ""
        if unit.hasPrefix("day") { return "\(number)d" }
        if unit.hasPrefix("hour") { return "\(number)h" }
        if unit.hasPrefix("minute") { return "\(number)m" }
        return String(number)
    }

    private func creditTooltip(_ credit: QuotaAnalyticsRow) -> String {
        let suffix = credit.value.isEmpty ? "" : " - \(credit.value)"
        return "Expires: \(credit.title)\(suffix)"
    }
}

private struct ResetCreditChip: View {
    let label: String
    let tooltip: String
    let isNext: Bool

    var body: some View {
        Text(label)
            .font(.system(size: 12, weight: .medium, design: .monospaced))
            .foregroundStyle(isNext ? Color.blue : .secondary)
            .lineLimit(1)
            .padding(.horizontal, 8)
            .padding(.vertical, 4)
            .background(
                Capsule(style: .continuous)
                    .fill(isNext ? Color.blue.opacity(0.18) : Color.primary.opacity(0.08))
            )
            .contentShape(Capsule(style: .continuous))
            .menuNativeTooltip(tooltip)
    }
}

private struct AnalyticsMetricStripView: View {
    let rows: [QuotaAnalyticsRow]

    var body: some View {
        HStack(spacing: 0) {
            ForEach(Array(rows.enumerated()), id: \.element.id) { index, row in
                AnalyticsMetricTileView(row: row)
                    .frame(maxWidth: .infinity)

                if index < rows.count - 1 {
                    Rectangle()
                        .fill(.separator.opacity(0.45))
                        .frame(width: 1, height: 34)
                }
            }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 8)
        .background(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .fill(Color.primary.opacity(0.025))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .stroke(.separator.opacity(0.45), lineWidth: 1)
        )
    }
}

private struct AnalyticsMetricTileView: View {
    let row: QuotaAnalyticsRow

    private var displayValue: String {
        switch row.id {
        case "codex-lifetime-tokens", "codex-peak-daily":
            row.value.replacingOccurrences(of: " tokens", with: "")
        default:
            row.value
        }
    }

    var body: some View {
        VStack(spacing: 4) {
            Text(displayValue)
                .font(.system(size: 13, weight: .semibold, design: .monospaced))
                .foregroundStyle(row.isAvailable ? .primary : .secondary)
                .lineLimit(1)
                .minimumScaleFactor(0.8)

            Text(row.title)
                .font(.system(size: 11, weight: .medium, design: .monospaced))
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .truncationMode(.tail)
        }
        .multilineTextAlignment(.center)
        .padding(.horizontal, 6)
        .frame(minWidth: 82)
    }
}

private struct AnalyticsRowView: View {
    let row: QuotaAnalyticsRow

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 12) {
            Text(row.title)
                .font(.system(size: 10, weight: .semibold, design: .rounded))
                .foregroundStyle(row.isAvailable ? .primary : .secondary)
                .lineLimit(1)

            Spacer(minLength: 8)

            Text(row.value)
                .font(.system(size: 10, weight: .medium, design: .rounded))
                .foregroundStyle(row.isAvailable ? .primary : .secondary)
                .multilineTextAlignment(.trailing)
                .lineLimit(1)
        }
    }
}
