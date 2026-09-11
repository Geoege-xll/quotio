import SwiftUI

/// 仪表盘筛选精炼为单行轻量工具栏：左侧快速切换常用时间范围，右侧展示已选条件摘要与“更多筛选”入口。
/// 彻底移除分组与提供商冗余胶囊，分组下沉至分布图表头，复杂筛选统一收归“更多筛选”面板。
struct CPAUsageFilterCard: View {
    @Binding var selection: CPAUsageSelection
    let options: CPAUsageEventPage?
    @Binding var dimension: CPAUsageDimension
    @Binding var metric: CPAUsageChartMetric
    var isAvailable = true
    /// 完整面板打开后只读全时间目录；可选闭包让离屏预览直接使用构造选项，不访问用户数据。
    var loadOptions: (() async throws -> CPAUsageFilterOptions)? = nil
    let onApply: (CPAUsageFilterDraft) -> Void
    @State private var presentedFilters: PresentedFilters?
    @Environment(\.colorScheme) private var colorScheme

    /// 条件在点击时冻结，当前页面选项仅作为加载占位；完整目录独立恢复，不重置草稿。
    private struct PresentedFilters: Identifiable {
        let id = UUID()
        let draft: CPAUsageFilterDraft
        let options: CPAUsageEventPage?
    }

    private var current: CPAUsageFilterDraft {
        .init(selection: selection, dimension: dimension, metric: metric)
    }

    private var rangeChoices: [CPAUsageFilterChoice] {
        CPAUsageTimeRange.dashboardOptions.map { .init(id: $0.rawValue, title: $0.titleKey.localized()) }
    }

    private var rangeBinding: Binding<CPAUsageFilterChoice> {
        Binding(get: {
            .init(id: selection.range.rawValue, title: selection.range.titleKey.localized())
        }, set: {
            if let range = CPAUsageTimeRange(rawValue: $0.id) { selection.range = range }
        })
    }

    private var activeConditions: [String] {
        CPAUsageFilterSummary(selection: selection, options: options).conditions
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            ViewThatFits(in: .horizontal) {
                // 宽屏模式：单行展示常用时间、激活标签与操作入口
                HStack(spacing: 8) {
                    timeRangeControl
                    Spacer(minLength: 8)
                    if selection.range == .custom {
                        customRangeBadge
                    }
                    if !activeConditions.isEmpty {
                        activeConditionsBadges
                    }
                    if current.hiddenConditionCount > 0 {
                        resetButton
                    }
                    moreFiltersButton
                }

                // 窄屏或标签较多时：第一行保留时间与操作入口，第二行自适应展示激活标签
                VStack(alignment: .leading, spacing: 8) {
                    HStack(spacing: 8) {
                        timeRangeControl
                        Spacer(minLength: 8)
                        if current.hiddenConditionCount > 0 {
                            resetButton
                        }
                        moreFiltersButton
                    }

                    if selection.range == .custom || !activeConditions.isEmpty {
                        HStack(spacing: 6) {
                            if selection.range == .custom {
                                customRangeBadge
                            }
                            if !activeConditions.isEmpty {
                                activeConditionsBadges
                            }
                            Spacer()
                        }
                    }
                }
            }

            if !isAvailable {
                Label("usage.cpa.legacyScope".localized(), systemImage: "info.circle")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
        .padding(10)
        .background(
            QuotioTheme.Colors.cardBackground(for: colorScheme),
            in: RoundedRectangle(cornerRadius: QuotioTheme.Radius.lg, style: .continuous)
        )
        .overlay(
            RoundedRectangle(cornerRadius: QuotioTheme.Radius.lg, style: .continuous)
                .strokeBorder(QuotioTheme.Colors.sidebarBorder(for: colorScheme), lineWidth: 0.5)
        )
        .sheet(item: $presentedFilters) { presentation in
            CPAUsageAdvancedFilterSheet(draft: presentation.draft, options: presentation.options,
                                        loadOptions: loadOptions, onApply: onApply)
        }
    }

    private var timeRangeControl: some View {
        QuotioCapsuleSegmentedControl(
            rangeChoices,
            selection: rangeBinding,
            size: .small,
            tint: .accentColor,
            isEqualWidth: false,
            title: { $0.title }
        )
        .disabled(!isAvailable)
    }

    private var customRangeBadge: some View {
        HStack(spacing: 4) {
            Image(systemName: "calendar")
                .font(.system(size: 10))
            Text(CPAUsageFilterSummary(selection: selection, options: options).rangeTitle)
                .font(.caption2.weight(.medium))
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 4)
        .background(QuotioTheme.Colors.cardInset(for: colorScheme), in: Capsule())
        .overlay(
            Capsule().strokeBorder(QuotioTheme.Colors.sidebarBorder(for: colorScheme), lineWidth: 0.5)
        )
        .foregroundStyle(.secondary)
    }

    private var activeConditionsBadges: some View {
        HStack(spacing: 6) {
            ForEach(activeConditions.prefix(2), id: \.self) { condition in
                Text(condition)
                    .font(.caption2.weight(.medium))
                    .padding(.horizontal, 8)
                    .padding(.vertical, 4)
                    .background(QuotioTheme.Colors.cardInset(for: colorScheme), in: Capsule())
                    .overlay(
                        Capsule().strokeBorder(QuotioTheme.Colors.sidebarBorder(for: colorScheme), lineWidth: 0.5)
                    )
                    .foregroundStyle(.secondary)
            }
            if activeConditions.count > 2 {
                Text("+\(activeConditions.count - 2)")
                    .font(.caption2.weight(.semibold))
                    .padding(.horizontal, 6)
                    .padding(.vertical, 4)
                    .background(QuotioTheme.Colors.cardInset(for: colorScheme), in: Capsule())
                    .foregroundStyle(.secondary)
            }
        }
    }

    private var resetButton: some View {
        Button {
            withAnimation(.easeInOut(duration: 0.15)) {
                selection.provider = ""
                selection.model = ""
                selection.source = ""
                selection.apiKey = ""
                selection.outcome = .all
                if selection.range == .custom {
                    selection.range = .today
                }
                dimension = .model
                metric = .tokens
            }
        } label: {
            Image(systemName: "arrow.counterclockwise")
                .font(.system(size: 11, weight: .medium))
        }
        .buttonStyle(.quotioMicroCapsule(height: 26))
        .help("usage.cpa.resetFilters".localized())
        .accessibilityLabel("usage.cpa.resetFilters".localized())
    }

    private var moreFiltersButton: some View {
        Button {
            presentedFilters = PresentedFilters(draft: current, options: options)
        } label: {
            HStack(spacing: 5) {
                Image(systemName: "slider.horizontal.3")
                    .font(.system(size: 11, weight: .medium))
                Text("usage.dashboard.moreFilters".localized())
                    .font(.system(size: 12, weight: .medium))
                if current.hiddenConditionCount > 0 {
                    Text("\(current.hiddenConditionCount)")
                        .font(.system(size: 10, weight: .bold, design: .rounded))
                        .padding(.horizontal, 5)
                        .padding(.vertical, 1.5)
                        .background(Color.accentColor)
                        .foregroundStyle(.white)
                        .clipShape(Capsule())
                }
            }
        }
        .buttonStyle(.quotioMicroCapsule(height: 26))
        .disabled(!isAvailable)
        .help(String(format: "usage.dashboard.hiddenFilters".localized(), current.hiddenConditionCount))
        .accessibilityLabel("usage.dashboard.moreFilters".localized())
        .accessibilityIdentifier("cpaMoreFiltersButton")
    }
}

/// 明细和价格页复用标题行，重置只更新该页面自己的查询条件。
struct CPAUsageFilterHeader: View {
    @Binding var selection: CPAUsageSelection
    var isAvailable = true
    @State private var showsPrivacy = false
    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        let activeCount = CPAUsageFilterSummary(selection: selection, options: nil).activeCount
        HStack(spacing: 8) {
            Label("usage.dashboard.filters".localized(), systemImage: "line.3.horizontal.decrease")
                .font(.headline).accessibilityAddTraits(.isHeader)
                .fixedSize()
            if isAvailable, activeCount > 0 {
                Text(String(format: "usage.dashboard.activeFilters".localized(), activeCount))
                    .font(.caption).monospacedDigit().foregroundStyle(.secondary)
                    .padding(.horizontal, 8).frame(height: 20)
                    .background(QuotioTheme.Colors.cardTag(for: colorScheme), in: Capsule())
                    .fixedSize()
            }
            Spacer(minLength: 8)
            Button {
                selection = CPAUsageSelection(range: .all)
            } label: {
                Label("usage.cpa.resetFilters".localized(), systemImage: "arrow.counterclockwise")
            }
            .buttonStyle(.bordered).controlSize(.small)
            .disabled(!isAvailable || activeCount == 0)
            Button { showsPrivacy = true } label: {
                Image(systemName: "info.circle")
            }
            .buttonStyle(.borderless)
            .help("usage.dashboard.filterHelp".localized())
            .accessibilityLabel("usage.dashboard.filterHelp".localized())
            .popover(isPresented: $showsPrivacy) {
                Text("usage.records.privacy".localized())
                    .font(.callout).padding(16).frame(width: 320, alignment: .leading)
            }
        }
    }
}

/// 只从当前选择生成展示文案，不依赖统计请求完成，也不回写选择或触发额外查询。
/// 选项标题来自已有索引；后台更新暂时缺少选项时保留当前值，避免误显示为“全部”。
struct CPAUsageFilterSummary {
    let selection: CPAUsageSelection
    let options: CPAUsageEventPage?

    var activeCount: Int {
        (selection.range == .all ? 0 : 1) + [selection.provider, selection.model, selection.source, selection.apiKey]
            .filter { !$0.isEmpty }.count + (selection.outcome == .all ? 0 : 1)
    }

    var rangeTitle: String {
        if selection.range == .custom {
            // 摘要与展开字段共用精确时间，避免不同小时窗口被显示成相同范围。
            return selection.start.formatted(date: .abbreviated, time: .shortened) + " – "
                + selection.end.formatted(date: .abbreviated, time: .shortened)
        }
        return selection.range.titleKey.localized()
    }

    var conditions: [String] {
        var values: [String] = []
        for (key, value, items) in [
            ("usage.provider", selection.provider, options?.providers ?? []),
            ("usage.model", selection.model, options?.models ?? []),
            ("usage.records.source", selection.source, options?.sources ?? []),
            ("usage.records.apiKey", selection.apiKey, options?.apiKeys ?? [])
        ] where !value.isEmpty {
            let title = value == "__unknown__" ? "usage.records.unknown".localized()
                : items.first { $0.id == value }?.title ?? value
            values.append(key.localized() + ": " + title)
        }
        if selection.outcome != .all {
            values.append("usage.records.result".localized() + ": " + selection.outcome.titleKey.localized())
        }
        return values
    }

    var fullText: String { ([rangeTitle] + conditions).joined(separator: " · ") }
}
