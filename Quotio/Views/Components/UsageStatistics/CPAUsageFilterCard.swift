import SwiftUI

/// 仪表盘筛选默认折叠，标题行保留当前条件摘要和完整面板入口；展开后显示三组常用条件。
/// 折叠只影响呈现，不清空选择、不重建查询状态，也不会触发采集任务。
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
    @State private var isExpanded = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    /// 条件在点击时冻结，当前页面选项仅作为加载占位；完整目录独立恢复，不重置草稿。
    private struct PresentedFilters: Identifiable {
        let id = UUID()
        let draft: CPAUsageFilterDraft
        let options: CPAUsageEventPage?
    }
    private var current: CPAUsageFilterDraft { .init(selection: selection, dimension: dimension, metric: metric) }
    private var summaryText: String {
        let summary = CPAUsageFilterSummary(selection: selection, options: options)
        return [summary.fullText, "usage.dashboard.groupBy".localized() + ": " + dimension.titleKey.localized(),
                metric.titleKey.localized()].joined(separator: " · ")
    }
    private var providerChoices: [CPAUsageFilterChoice] {
        CPAUsageFilterChoice.options(options?.providers ?? [], selected: selection.provider,
            allTitle: "usage.records.outcome.all".localized(), unknownTitle: "usage.records.unknown".localized())
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 8) {
                Button {
                    withAnimation(reduceMotion ? nil : .easeInOut(duration: 0.18)) { isExpanded.toggle() }
                } label: {
                    HStack(spacing: 8) {
                        Image(systemName: "chevron.right").font(.caption.weight(.semibold))
                            .foregroundStyle(.secondary).rotationEffect(.degrees(isExpanded ? 90 : 0))
                        Text("usage.dashboard.filters".localized()).font(.headline).fixedSize()
                        if !isExpanded {
                            Text(summaryText).font(.caption).foregroundStyle(.secondary)
                                .lineLimit(1).truncationMode(.middle)
                        }
                        Spacer(minLength: 0)
                    }
                    .frame(maxWidth: .infinity, minHeight: 24, alignment: .leading)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .help(summaryText)
                .accessibilityLabel((isExpanded ? "usage.dashboard.collapseFilters" : "usage.dashboard.expandFilters").localized())
                .accessibilityValue(summaryText)
                .accessibilityIdentifier("cpaToggleFiltersButton")
                Button {
                    presentedFilters = PresentedFilters(draft: current, options: options)
                } label: {
                    HStack(spacing: 6) {
                        Text("usage.dashboard.moreFilters".localized())
                        if current.hiddenConditionCount > 0 {
                            Text(current.hiddenConditionCount.formatted()).monospacedDigit()
                        }
                    }
                }
                .buttonStyle(.bordered).controlSize(.small).fixedSize()
                .disabled(!isAvailable)
                .help(String(format: "usage.dashboard.hiddenFilters".localized(), current.hiddenConditionCount))
                .accessibilityLabel("usage.dashboard.moreFilters".localized())
                .accessibilityValue(String(format: "usage.dashboard.hiddenFilters".localized(), current.hiddenConditionCount))
                .accessibilityIdentifier("cpaMoreFiltersButton")
            }

            if isExpanded {
                expandedControls
                    .disabled(!isAvailable)
                    .transition(.opacity)
            }

            if !isAvailable {
                Label("usage.cpa.legacyScope".localized(), systemImage: "info.circle")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
        .quotioCard(cornerRadius: QuotioTheme.Radius.lg, padding: 14)
        .sheet(item: $presentedFilters) { presentation in
            CPAUsageAdvancedFilterSheet(draft: presentation.draft, options: presentation.options,
                                        loadOptions: loadOptions, onApply: onApply)
        }
    }

    /// 完整面板始终挂在卡片上，不依赖展开区域；收起时也可直接编辑自定义时间等全部条件。
    private var expandedControls: some View {
        VStack(alignment: .leading, spacing: 12) {
            rangeControls
            // 并排时每组还需容纳标签和四项分段，至少 390pt 才能保留主要选项可读空间。
            CPAUsageAdaptiveGrid(maximumColumns: 2, minimumColumnWidth: 390) {
                filterCluster("usage.dashboard.groupBy", icon: "chart.bar.xaxis") {
                    ScrollView(.horizontal) {
                        QuotioCapsuleSegmentedControl(dimensionChoices, selection: dimensionBinding,
                            size: .medium, tint: .accentColor, isEqualWidth: false, title: { $0.title })
                    }.scrollIndicators(.hidden).frame(height: 38)
                }
                filterCluster("usage.provider", icon: "square.stack.3d.up") {
                    ScrollView(.horizontal) {
                        QuotioCapsuleSegmentedControl(providerChoices, selection: providerBinding,
                            size: .medium, optionTint: providerTint, isEqualWidth: false, title: { $0.title })
                    }.scrollIndicators(.hidden).frame(height: 38)
                }
            }
        }
    }

    private var rangeControls: some View {
        filterCluster("usage.records.range", icon: "calendar") {
            ScrollView(.horizontal) {
                QuotioCapsuleSegmentedControl(rangeChoices, selection: rangeBinding,
                    size: .medium, tint: .accentColor, isEqualWidth: false, title: { $0.title })
            }.scrollIndicators(.hidden).frame(height: 38)
        }
    }

    private func filterCluster<Content: View>(_ key: String, icon: String, @ViewBuilder content: () -> Content) -> some View {
        HStack(spacing: 10) {
            Label(key.localized(), systemImage: icon).font(.caption2.weight(.semibold))
                .foregroundStyle(.secondary).frame(width: 64, alignment: .leading)
                .fixedSize(horizontal: false, vertical: true)
            content().frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private var rangeChoices: [CPAUsageFilterChoice] {
        CPAUsageTimeRange.dashboardOptions.map { .init(id: $0.rawValue, title: $0.titleKey.localized()) }
    }
    private var dimensionChoices: [CPAUsageFilterChoice] {
        CPAUsageDimension.allCases.map { .init(id: $0.rawValue, title: $0.titleKey.localized()) }
    }
    private var rangeBinding: Binding<CPAUsageFilterChoice> {
        Binding(get: { .init(id: selection.range.rawValue, title: selection.range.titleKey.localized()) }, set: {
            if let range = CPAUsageTimeRange(rawValue: $0.id) { selection.range = range }
        })
    }
    private var dimensionBinding: Binding<CPAUsageFilterChoice> {
        Binding(get: { .init(id: dimension.rawValue, title: dimension.titleKey.localized()) }, set: {
            if let value = CPAUsageDimension(rawValue: $0.id) { dimension = value }
        })
    }
    private var providerBinding: Binding<CPAUsageFilterChoice> {
        Binding(get: {
            providerChoices.first { $0.id == selection.provider } ?? .init(id: selection.provider, title: selection.provider)
        }, set: { selection.provider = $0.id })
    }
    private func providerTint(_ choice: CPAUsageFilterChoice) -> Color? {
        // 品牌只影响外观，仍按数据库原始 ID 筛选；不把自定义 OpenAI 兼容服务猜成 Codex。
        let provider = AIProvider(rawValue: choice.id.lowercased())
            ?? AIProvider.allCases.first { $0.displayName.caseInsensitiveCompare(choice.title) == .orderedSame }
        return provider?.color ?? .accentColor
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
