import SwiftUI

/// Antigravity 分组额度的卡片行，保留同一模型/额度桶的原有分组输入与显示顺序。
/// 适配单列满宽与多列网格（一行两个），文字单行截断并统一圆角内衬槽位背景。
struct AntigravityGroupRow: View {
    @Environment(\.colorScheme) private var colorScheme
    let group: AntigravityDisplayGroup

    private var settings: MenuBarSettingsManager { MenuBarSettingsManager.shared }

    private var displayHelper: QuotaDisplayHelper {
        QuotaDisplayHelper(displayMode: settings.quotaDisplayMode)
    }

    private var remainingPercent: Double {
        group.percentage
    }

    private var groupIcon: String {
        if group.name.contains("Claude") { return "brain.head.profile" }
        if group.name.contains("Image") { return "photo" }
        if group.name.contains("Flash") { return "bolt.fill" }
        return "sparkles"
    }

    var body: some View {
        let displayPercent = remainingPercent < 0 ? 0 : displayHelper.displayPercent(remainingPercent: remainingPercent)
        let statusColor: Color = remainingPercent < 0 ? .secondary : displayHelper.statusColor(remainingPercent: remainingPercent)

        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 8) {
                Image(systemName: groupIcon)
                    .font(.caption)
                    .foregroundStyle(.tertiary)
                    .frame(width: 16)

                Text(group.name)
                    .font(.subheadline)
                    .fontWeight(.medium)
                    .lineLimit(1)
                    .truncationMode(.tail)

                if group.models.count > 1 {
                    Text(String(group.models.count))
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                        .padding(.horizontal, 4)
                        .padding(.vertical, 1)
                        .background(Color.primary.opacity(0.05))
                        .clipShape(Capsule())
                }

                Spacer(minLength: 4)

                Text(remainingPercent < 0 ? "—" : String(format: "%.0f%%", displayPercent))
                    .font(.subheadline)
                    .fontWeight(.semibold)
                    .foregroundStyle(statusColor)
                    .monospacedDigit()
                    .lineLimit(1)

                if let firstModel = group.models.first,
                   firstModel.formattedResetTime != "—" && !firstModel.formattedResetTime.isEmpty {
                    Text(firstModel.formattedResetTime)
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                        .lineLimit(1)
                }
            }

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
        .padding(.horizontal, 10)
        .padding(.vertical, 8)
        .background(
            QuotioTheme.Colors.cardInset(for: colorScheme).opacity(0.6),
            in: RoundedRectangle(cornerRadius: QuotioTheme.Radius.sm, style: .continuous)
        )
    }
}

/// 最低额度主行及其余分组的紧凑布局，未知额度、颜色、尺寸和修饰器顺序均保持不变。
struct AntigravityLowestBarLayout: View {
    @Environment(\.colorScheme) private var colorScheme
    let groups: [AntigravityDisplayGroup]

    private var settings: MenuBarSettingsManager { MenuBarSettingsManager.shared }
    private var displayHelper: QuotaDisplayHelper {
        QuotaDisplayHelper(displayMode: settings.quotaDisplayMode)
    }

    private var sorted: [AntigravityDisplayGroup] {
        // 共用明细已将未知额度放在末尾，避免未知值抢占最低额度主行。
        groups
    }

    private var lowest: AntigravityDisplayGroup? {
        sorted.first
    }

    private var others: [AntigravityDisplayGroup] {
        Array(sorted.dropFirst())
    }

    private func displayPercent(for remainingPercent: Double) -> Double {
        remainingPercent < 0 ? 0 : displayHelper.displayPercent(remainingPercent: remainingPercent)
    }

    var body: some View {
        VStack(spacing: 10) {
            if let lowest = lowest {
                let statusColor = lowest.percentage < 0 ? Color.secondary : displayHelper.statusColor(remainingPercent: lowest.percentage)
                // Hero row for bottleneck
                VStack(alignment: .leading, spacing: 6) {
                    HStack {
                        Text(lowest.name)
                            .font(.subheadline)
                            .fontWeight(.semibold)
                        Spacer()
                        Text(lowest.percentage < 0 ? "—" : String(format: "%.0f%%", displayPercent(for: lowest.percentage)))
                            .font(.subheadline)
                            .fontWeight(.bold)
                            .foregroundStyle(statusColor)
                            .monospacedDigit()
                    }

                    GeometryReader { proxy in
                        ZStack(alignment: .leading) {
                            Capsule()
                                .fill(Color.primary.opacity(0.06))
                            Capsule()
                                .fill(statusColor.gradient)
                                .frame(width: proxy.size.width * (displayPercent(for: lowest.percentage) / 100))
                        }
                    }
                    .frame(height: 8)
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
                    ForEach(others) { group in
                        HStack {
                            Text(group.name)
                                .font(.caption)
                                .foregroundStyle(.secondary)
                            Spacer()
                            Text(group.percentage < 0 ? "—" : String(format: "%.0f%%", displayPercent(for: group.percentage)))
                                .font(.caption)
                                .fontWeight(.medium)
                                .foregroundStyle((group.percentage < 0 ? Color.secondary : displayHelper.statusColor(remainingPercent: group.percentage)))
                                .monospacedDigit()
                        }
                    }
                }
            }
        }
    }
}

/// 环形额度布局，仅负责展示父卡片传入的分组；网格列数与未知状态仍沿用原规则。
struct AntigravityRingLayout: View {
    let groups: [AntigravityDisplayGroup]

    private var settings: MenuBarSettingsManager { MenuBarSettingsManager.shared }
    private var displayHelper: QuotaDisplayHelper {
        QuotaDisplayHelper(displayMode: settings.quotaDisplayMode)
    }

    private var columns: [GridItem] {
        let count = min(max(groups.count, 1), 4)
        return Array(repeating: GridItem(.flexible(), spacing: 12), count: count)
    }

    private func ringPercent(for remainingPercent: Double) -> Double {
        displayHelper.ringPercent(remainingPercent: remainingPercent)
    }

    var body: some View {
        LazyVGrid(columns: columns, spacing: 12) {
            ForEach(groups) { group in
                VStack(spacing: 6) {
                    RingProgressView(
                        percent: ringPercent(for: group.percentage),
                        size: 44,
                        lineWidth: 5,
                        tint: (group.percentage < 0 ? Color.secondary : displayHelper.statusColor(remainingPercent: group.percentage)),
                        showLabel: true
                    )

                    Text(group.name)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
            }
        }
    }
}
