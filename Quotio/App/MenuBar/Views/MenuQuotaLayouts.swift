//
//  MenuQuotaLayouts.swift
//  Quotio
//

import AppKit
import SwiftUI

/// 菜单栏额度的条形、环形、卡片布局及模型明细。
/// 跨文件消费的数据、三种布局和模型明细类型仅提升为模块内可见；百分比函数、进度条和徽章继续私有。
/// 百分比口径、颜色、格式化和视图层级完整保留，不引入新的额度投影或状态来源。
struct ModelBadgeData: Identifiable {
    let name: String
    let percentage: Double
    let resetTime: String?
    let usage: String?
    let sourceID: String?

    init(name: String, percentage: Double, resetTime: String?, usage: String? = nil, sourceID: String? = nil) {
        self.name = name
        self.percentage = percentage
        self.resetTime = resetTime
        self.usage = usage
        self.sourceID = sourceID
    }

    // 上游不同额度桶可以同名；界面身份必须保留原 ID，避免 SwiftUI 合并行。
    var id: String { sourceID ?? name }

    var formattedResetTime: String? {
        guard let resetTime = resetTime else { return nil }

        // Try parsing with fractional seconds first, then standard format
        let isoFormatterWithFractional = ISO8601DateFormatter()
        isoFormatterWithFractional.formatOptions = [.withInternetDateTime, .withFractionalSeconds]

        let isoFormatterStandard = ISO8601DateFormatter()
        isoFormatterStandard.formatOptions = [.withInternetDateTime]

        guard let date = isoFormatterWithFractional.date(from: resetTime)
              ?? isoFormatterStandard.date(from: resetTime) else { return nil }

        let now = Date()
        let diff = date.timeIntervalSince(now)
        guard diff > 0 else { return nil }

        let totalMinutes = Int(diff) / 60
        let days = totalMinutes / 1440  // 24 * 60
        let hours = (totalMinutes % 1440) / 60
        let minutes = totalMinutes % 60

        if days > 0 {
            return "\(days)d\(hours)h"
        } else if hours > 0 {
            return "\(hours)h\(minutes)m"
        } else {
            return "\(minutes)m"
        }
    }
}

private func menuDisplayPercent(remainingPercent: Double, displayMode: QuotaDisplayMode) -> Double {
    displayMode.displayValue(from: remainingPercent)
}

/// Formatted percentage for menu rows. A negative remaining percentage means
/// "no data yet" and renders as a placeholder instead of a fake value like 101%.
private func menuPercentText(remainingPercent: Double, displayMode: QuotaDisplayMode) -> String {
    // 与配额页统一未知值、上下界和四舍五入，避免菜单截断为 59% 而页面显示 60%。
    QuotaPercentagePresentation.text(remainingPercent, showUsed: displayMode == .used)
}

private func menuStatusColor(remainingPercent: Double, displayMode: QuotaDisplayMode) -> Color {
    guard remainingPercent >= 0 else { return .secondary }
    let usedPercent = 100 - remainingPercent
    let checkValue = displayMode == .used ? usedPercent : remainingPercent

    if displayMode == .used {
        if checkValue < 70 { return .green }
        if checkValue < 90 { return .yellow }
        return .red
    } else {
        if checkValue > 50 { return .green }
        if checkValue > 20 { return .orange }
        return .red
    }
}

// MARK: - Layout Subviews

struct LowestBarLayout: View {
    let models: [ModelBadgeData]
    
    /// 沿用父级同一偏好；默认 shared 保持原有构造兼容。
    var settings: MenuBarSettingsManager = .shared

    private var sorted: [ModelBadgeData] {
        // 未知额度不应排在有效最低额度之前，否则状态栏主行会被占位数据覆盖。
        models.sorted {
            let left = QuotaPercentagePresentation.isKnown($0.percentage) ? $0.percentage : Double.infinity
            let right = QuotaPercentagePresentation.isKnown($1.percentage) ? $1.percentage : Double.infinity
            return left == right ? $0.id < $1.id : left < right
        }
    }

    private var lowest: ModelBadgeData? {
        sorted.first
    }

    private var others: [ModelBadgeData] {
        Array(sorted.dropFirst())
    }

    var body: some View {
        let displayMode = settings.quotaDisplayMode
        
        VStack(spacing: 6) {
            if let lowest = lowest {
                // Hero Row for Lowest with reset time
                VStack(alignment: .leading, spacing: 6) {
                    HStack {
                        Text(lowest.name)
                            .font(.system(size: 12, weight: .semibold, design: .rounded))
                            .foregroundStyle(.primary)
                        Spacer()
                        PercentageBadge(percentage: lowest.percentage, style: .textOnly, settings: settings)
                    }

                    ModernProgressBar(percentage: lowest.percentage, height: 6, settings: settings)

                    if let resetTime = lowest.formattedResetTime {
                        HStack(spacing: 4) {
                            Image(systemName: "clock.arrow.circlepath")
                                .font(.system(size: 9))
                            Text(resetTime)
                                .font(.system(size: 9, weight: .medium, design: .rounded))
                        }
                        .foregroundStyle(.tertiary)
                    }
                }
                .padding(6)
                .background(menuStatusColor(remainingPercent: lowest.percentage, displayMode: displayMode).opacity(0.08))
                .clipShape(RoundedRectangle(cornerRadius: 8))
                .overlay(
                    RoundedRectangle(cornerRadius: 8)
                        .stroke(menuStatusColor(remainingPercent: lowest.percentage, displayMode: displayMode).opacity(0.2), lineWidth: 1)
                )
            }

            // Others as text rows (one per line)
            if !others.isEmpty {
                VStack(spacing: 4) {
                    ForEach(others, id: \.id) { (model: ModelBadgeData) in
                        HStack(spacing: 6) {
                            Text(model.name)
                                .font(.system(size: 10, weight: .medium, design: .rounded))
                                .foregroundStyle(.secondary)
                                .lineLimit(1)
                            Spacer()
                            if let resetTime = model.formattedResetTime {
                                Text(resetTime)
                                    .font(.system(size: 9, design: .rounded))
                                    .foregroundStyle(.tertiary)
                            }
                            Text(menuPercentText(remainingPercent: model.percentage, displayMode: displayMode))
                                .font(.system(size: 10, weight: .bold, design: .monospaced))
                                .foregroundStyle(menuStatusColor(remainingPercent: model.percentage, displayMode: displayMode))
                        }
                        .padding(.vertical, 2)
                    }
                }
            }
        }
    }
}

struct RingGridLayout: View {
    let models: [ModelBadgeData]
    
    /// 沿用父级同一偏好；默认 shared 保持原有构造兼容。
    var settings: MenuBarSettingsManager = .shared

    private var columnCount: Int {
        min(max(models.count, 1), 4)
    }

    private var columns: [GridItem] {
        Array(repeating: GridItem(.flexible()), count: columnCount)
    }

    private var ringSize: CGFloat {
        columnCount >= 4 ? 36 : 40
    }

    var body: some View {
        let displayMode = settings.quotaDisplayMode
        
        // Auto-distribute 1-4 columns, cap at 4
        LazyVGrid(columns: columns, spacing: 6) {
            ForEach(models, id: \.id) { (model: ModelBadgeData) in
                VStack(spacing: 4) {
                    RingProgressView(percent: menuDisplayPercent(remainingPercent: model.percentage, displayMode: displayMode), size: ringSize, lineWidth: 4, tint: menuStatusColor(remainingPercent: model.percentage, displayMode: displayMode), showLabel: true)

                    Text(model.name)
                        .font(.system(size: 10, weight: .medium, design: .rounded))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .minimumScaleFactor(0.8)

                    if let resetTime = model.formattedResetTime {
                        Text(resetTime)
                            .font(.system(size: 8, design: .rounded))
                            .foregroundStyle(.tertiary)
                    }
                }
                .frame(maxWidth: .infinity)
            }
        }
    }
}

struct CardGridLayout: View {
    let models: [ModelBadgeData]
    
    /// 沿用父级同一偏好；默认 shared 保持原有构造兼容。
    var settings: MenuBarSettingsManager = .shared

    private var columns: [GridItem] {
        // Single metric: full width. Multiple: 2 columns
        if models.count == 1 {
            return [GridItem(.flexible())]
        } else {
            return [GridItem(.flexible()), GridItem(.flexible())]
        }
    }
    
    var body: some View {
        let displayMode = settings.quotaDisplayMode
        
        LazyVGrid(columns: columns, spacing: 6) {
            ForEach(models, id: \.id) { (model: ModelBadgeData) in
                VStack(alignment: .leading, spacing: 4) {
                    HStack {
                        Text(model.name)
                            .font(.system(size: 10, weight: .medium, design: .rounded))
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                        Spacer()
                        if let resetTime = model.formattedResetTime {
                            Text(resetTime)
                                .font(.system(size: 9, design: .rounded))
                                .foregroundStyle(.tertiary)
                        }
                        if let usage = model.usage {
                            Text(usage)
                                .font(.system(size: 10, weight: .bold, design: .monospaced))
                                .foregroundStyle(.primary)
                        } else {
                            Text(menuPercentText(remainingPercent: model.percentage, displayMode: displayMode))
                                .font(.system(size: 10, weight: .bold, design: .monospaced))
                                .foregroundStyle(menuStatusColor(remainingPercent: model.percentage, displayMode: displayMode))
                        }
                    }

                    if model.usage == nil {
                        ModernProgressBar(percentage: model.percentage, height: 4, settings: settings)
                    }
                }
                .padding(6)
                .background(Color.secondary.opacity(0.05))
                .clipShape(RoundedRectangle(cornerRadius: 8))
            }
        }
    }

}

// MARK: - Shared Components

private struct ModernProgressBar: View {
    let percentage: Double
    let height: CGFloat
    
    /// 沿用父级同一偏好；默认 shared 保持原有构造兼容。
    var settings: MenuBarSettingsManager = .shared
    
    private var displayPercent: Double {
        menuDisplayPercent(remainingPercent: percentage, displayMode: settings.quotaDisplayMode)
    }
    
    var color: Color {
        menuStatusColor(remainingPercent: percentage, displayMode: settings.quotaDisplayMode)
    }
    
    var body: some View {
        GeometryReader { proxy in
            ZStack(alignment: .leading) {
                Capsule()
                    .fill(Color.secondary.opacity(0.15))
                
                Capsule()
                    .fill(
                        LinearGradient(
                            colors: [color, color.opacity(0.8)],
                            startPoint: .leading,
                            endPoint: .trailing
                        )
                    )
                    .frame(width: proxy.size.width * min(1, max(0, displayPercent / 100)))
            }
        }
        .frame(height: height)
    }
}

private struct PercentageBadge: View {
    let percentage: Double
    var style: Style = .pill
    
    /// 沿用父级同一偏好；默认 shared 保持原有构造兼容。
    var settings: MenuBarSettingsManager = .shared
    
    enum Style { case pill, textOnly }
    
    var color: Color {
        menuStatusColor(remainingPercent: percentage, displayMode: settings.quotaDisplayMode)
    }

    private var displayText: String {
        menuPercentText(remainingPercent: percentage, displayMode: settings.quotaDisplayMode)
    }

    var body: some View {
        switch style {
        case .pill:
            Text(displayText)
                .font(.system(size: 10, weight: .bold, design: .monospaced))
                .foregroundStyle(color)
                .padding(.horizontal, 6)
                .padding(.vertical, 2)
                .background(color.opacity(0.1))
                .clipShape(Capsule())
        case .textOnly:
            Text(displayText)
                .font(.system(size: 12, weight: .bold, design: .monospaced))
                .foregroundStyle(color)
        }
    }
}

// MARK: Model Detail View (for submenu)

struct MenuModelDetailView: View {
    let model: ModelQuota
    let showRawName: Bool

    /// 沿用父级同一偏好；默认 shared 保持原有构造兼容。
    var settings: MenuBarSettingsManager = .shared

    private var statusColor: Color {
        menuStatusColor(remainingPercent: model.percentage, displayMode: settings.quotaDisplayMode)
    }

    var body: some View {
        let displayMode = settings.quotaDisplayMode
        let displayStyle = settings.quotaDisplayStyle
        let displayPercent = menuDisplayPercent(remainingPercent: model.percentage, displayMode: displayMode)

        HStack(spacing: 8) {
            Text(showRawName ? model.name : model.displayName)
                .font(.system(size: 11, weight: .medium, design: showRawName ? .monospaced : .rounded))
                .foregroundStyle(.primary)
                .lineLimit(1)
                .truncationMode(.middle)

            Spacer()

            if let usage = model.formattedUsage {
                Text(usage)
                    .font(.system(size: 10, design: .monospaced))
                    .foregroundStyle(.tertiary)
            }

            if !model.isStandaloneMetric && displayStyle != .ring {
                Text(displayPercent >= 0
                    ? String(format: "%.0f%% %@", displayPercent, displayMode.suffixKey.localized())
                    : "—")
                    .font(.system(size: 10, weight: .semibold, design: .rounded))
                    .foregroundStyle(statusColor)
            }

            if !model.isStandaloneMetric && model.formattedResetTime != "—" && !model.formattedResetTime.isEmpty {
                Text(model.formattedResetTime)
                    .font(.system(size: 9, design: .rounded))
                    .foregroundStyle(.tertiary)
            }

            if !model.isStandaloneMetric && displayStyle == .ring {
                if RingProgressView.isUnknown(displayPercent) {
                    // A 14pt ring has no room for a label, so replace it with the
                    // same placeholder the other display styles render.
                    Text("—")
                        .font(.system(size: 10, weight: .semibold, design: .rounded))
                        .foregroundStyle(statusColor)
                        .accessibilityLabel("usage.ring".localized())
                        .accessibilityValue("quota.noDataYet".localized())
                } else {
                    RingProgressView(percent: displayPercent, size: 14, lineWidth: 2, tint: statusColor)
                }
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 6)
    }
}
