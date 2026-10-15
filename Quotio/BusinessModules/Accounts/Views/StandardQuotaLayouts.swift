import SwiftUI

/// 标准提供商的最低额度布局，与本文件中的环形、卡片行和独立指标共同覆盖原有三种样式。
/// 四个入口仅供原 AccountQuotaContent 跨文件调用，内部计算属性保持 private。
/// 配额数据和样式选择仍来自父卡片，显示偏好仍读取原单例，不新增状态容器或刷新任务。
struct StandardLowestBarLayout: View {
    @Environment(\.colorScheme) private var colorScheme
    let models: [ModelQuota]

    private var settings: MenuBarSettingsManager { MenuBarSettingsManager.shared }
    private var displayHelper: QuotaDisplayHelper {
        QuotaDisplayHelper(displayMode: settings.quotaDisplayMode)
    }

    private var sorted: [ModelQuota] {
        // 未知值排在最后，不能覆盖真实最低额度；同值按模型身份稳定排序。
        QuotaPercentagePresentation.sorted(models)
    }

    private var lowest: ModelQuota? {
        sorted.first
    }

    private var others: [ModelQuota] {
        Array(sorted.dropFirst())
    }

    private func displayPercent(for remainingPercent: Double) -> Double {
        displayHelper.displayPercent(remainingPercent: remainingPercent)
    }

    var body: some View {
        VStack(spacing: 10) {
            if let lowest = lowest {
                let statusColor = displayHelper.statusColor(remainingPercent: lowest.percentage)
                // Hero row for bottleneck
                VStack(alignment: .leading, spacing: 6) {
                    HStack {
                        Text(lowest.displayName)
                            .font(.subheadline)
                            .fontWeight(.semibold)
                        Spacer()
                        Text(displayHelper.percentText(remainingPercent: lowest.percentage))
                            .font(.subheadline)
                            .fontWeight(.bold)
                            .foregroundStyle(statusColor)
                            .monospacedDigit()
                    }

                    GeometryReader { proxy in
                        ZStack(alignment: .leading) {
                            Capsule()
                                .fill(Color.primary.opacity(0.06))
                            if QuotaPercentagePresentation.isKnown(lowest.percentage) {
                                Capsule()
                                    .fill(statusColor.gradient)
                                    .frame(width: proxy.size.width * (displayPercent(for: lowest.percentage) / 100))
                            }
                        }
                    }
                    .frame(height: 8)

                    if lowest.formattedResetTime != "—" && !lowest.formattedResetTime.isEmpty {
                        Text(lowest.formattedResetTime)
                            .font(.caption2)
                            .foregroundStyle(.tertiary)
                    }
                }
                .padding(11)
                .background(
                    statusColor.opacity(colorScheme == .dark ? 0.14 : 0.08),
                    in: RoundedRectangle(cornerRadius: QuotioTheme.Radius.md, style: .continuous)
                )
                .overlay(
                    RoundedRectangle(cornerRadius: QuotioTheme.Radius.md, style: .continuous)
                        .strokeBorder(
                            statusColor.opacity(colorScheme == .dark ? 0.28 : 0.16),
                            lineWidth: 0.5
                        )
                )
            }

            // Others as compact text rows
            if !others.isEmpty {
                VStack(spacing: 4) {
                    ForEach(others) { model in
                        HStack {
                            Text(model.displayName)
                                .font(.caption)
                                .foregroundStyle(.secondary)
                            Spacer()
                            if model.formattedResetTime != "—" && !model.formattedResetTime.isEmpty {
                                Text(model.formattedResetTime)
                                    .font(.caption2)
                                    .foregroundStyle(.tertiary)
                            }
                            Text(displayHelper.percentText(remainingPercent: model.percentage))
                                .font(.caption)
                                .fontWeight(.medium)
                                .foregroundStyle(displayHelper.statusColor(remainingPercent: model.percentage))
                                .monospacedDigit()
                        }
                    }
                }
            }
        }
    }
}

/// 标准提供商的环形布局；未知额度哨兵、每行列数及重置时间的展示行为保持原样。
struct StandardRingLayout: View {
    let models: [ModelQuota]

    private var settings: MenuBarSettingsManager { MenuBarSettingsManager.shared }
    private var displayHelper: QuotaDisplayHelper {
        QuotaDisplayHelper(displayMode: settings.quotaDisplayMode)
    }

    private var columns: [GridItem] {
        let count = min(max(models.count, 1), 4)
        return Array(repeating: GridItem(.flexible(), spacing: 12), count: count)
    }

    private func ringPercent(for remainingPercent: Double) -> Double {
        displayHelper.ringPercent(remainingPercent: remainingPercent)
    }

    var body: some View {
        LazyVGrid(columns: columns, spacing: 12) {
            ForEach(models) { model in
                VStack(spacing: 6) {
                    RingProgressView(
                        percent: ringPercent(for: model.percentage),
                        size: 44,
                        lineWidth: 5,
                        tint: displayHelper.statusColor(remainingPercent: model.percentage),
                        showLabel: true
                    )

                    Text(model.displayName)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)

                    if model.formattedResetTime != "—" && !model.formattedResetTime.isEmpty {
                        Text(model.formattedResetTime)
                            .font(.caption2)
                            .foregroundStyle(.tertiary)
                    }
                }
            }
        }
    }
}

/// 标准额度的卡片样式行，保留已用/剩余换算、详细读数和 tooltip 的既有调用契约。
/// 适配单列满宽与多列网格（一行两个），文字单行尾部截断并统一圆角内衬槽位背景。
struct UsageRowV2: View {
    @Environment(\.colorScheme) private var colorScheme
    let name: String
    let icon: String?
    let usedPercent: Double
    let used: Int?
    let limit: Int?
    let formattedUsage: String?
    let resetTime: String
    let tooltip: String?

    private var settings: MenuBarSettingsManager { MenuBarSettingsManager.shared }
    private var displayHelper: QuotaDisplayHelper {
        QuotaDisplayHelper(displayMode: settings.quotaDisplayMode)
    }

    private var isUnknown: Bool {
        usedPercent < 0 || usedPercent > 100
    }

    private var remainingPercent: Double {
        max(0, min(100, 100 - usedPercent))
    }

    var body: some View {
        let displayPercent = displayHelper.displayPercent(remainingPercent: remainingPercent)
        let statusColor = displayHelper.statusColor(remainingPercent: remainingPercent)

        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 8) {
                if let icon = icon {
                    Image(systemName: icon)
                        .font(.caption)
                        .foregroundStyle(.tertiary)
                        .frame(width: 16)
                }

                Text(name)
                    .font(.subheadline)
                    .fontWeight(.medium)
                    .lineLimit(1)
                    .truncationMode(.tail)
                    .help(tooltip ?? "")

                Spacer(minLength: 4)

                if let formattedUsage {
                    Text(formattedUsage)
                        .font(.caption)
                        .foregroundStyle(.tertiary)
                        .monospacedDigit()
                        .lineLimit(1)
                } else if let used = used {
                    if let limit = limit, limit > 0 {
                        Text(String(used) + "/" + String(limit))
                            .font(.caption)
                            .foregroundStyle(.tertiary)
                            .monospacedDigit()
                            .lineLimit(1)
                    }
                }

                if !isUnknown {
                    Text(String(format: "%.0f%%", displayPercent))
                        .font(.subheadline)
                        .fontWeight(.semibold)
                        .foregroundStyle(statusColor)
                        .monospacedDigit()
                        .lineLimit(1)
                } else {
                    Text("—")
                        .font(.subheadline)
                        .foregroundStyle(.tertiary)
                        .lineLimit(1)
                }

                if resetTime != "—" && !resetTime.isEmpty {
                    Text(resetTime)
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                        .lineLimit(1)
                }
            }

            if !isUnknown {
                GeometryReader { proxy in
                    ZStack(alignment: .leading) {
                        Capsule()
                            .fill(Color.primary.opacity(0.06))
                        Capsule()
                            .fill(statusColor.gradient)
                            .frame(width: proxy.size.width * (displayPercent / 100))
                    }
                }
                .frame(height: 6)
            }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 8)
        .background(
            QuotioTheme.Colors.cardInset(for: colorScheme).opacity(0.6),
            in: RoundedRectangle(cornerRadius: QuotioTheme.Radius.sm, style: .continuous)
        )
    }
}

/// 不适用百分比仪表的独立指标行，继续直接显示模型提供的格式化读数。
/// 布局与 UsageRowV2 保持一致的圆角内衬槽位，自适应网格排版。
struct StandaloneMetricRow: View {
    @Environment(\.colorScheme) private var colorScheme
    let model: ModelQuota

    var body: some View {
        HStack(spacing: 10) {
            Text(model.displayName)
                .font(.subheadline)
                .fontWeight(.medium)
                .lineLimit(1)
                .truncationMode(.tail)
            Spacer(minLength: 4)
            Text(model.formattedUsage ?? "—")
                .font(.subheadline)
                .fontWeight(.semibold)
                .foregroundStyle(.secondary)
                .monospacedDigit()
                .lineLimit(1)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 8)
        .background(
            QuotioTheme.Colors.cardInset(for: colorScheme).opacity(0.6),
            in: RoundedRectangle(cornerRadius: QuotioTheme.Radius.sm, style: .continuous)
        )
        .help(model.tooltip ?? "")
    }
}
