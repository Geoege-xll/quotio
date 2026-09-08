import SwiftUI
import Charts

/// 首页只负责组合独立观察边界，不读取采集心跳；总览、图表与底部时间各自更新。
struct CPAUsageStatisticsView: View {
    let store: UsageStatisticsStore
    let totalAccounts: Int
    let readyAccounts: Int
    @Binding var selection: CPAUsageSelection
    let dashboardModel: CPAUsageDashboardViewModel

    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            if let legacy = store.legacyTotals {
                // 旧版服务只有进程累计值，不假装支持日期筛选，也不拿空明细覆盖已有总量。
                CPALegacyUsageOverview(totals: legacy)
            } else {
                CPAUsageDashboardContent(store: store, selection: $selection,
                                         totalAccounts: totalAccounts, readyAccounts: readyAccounts,
                                         model: dashboardModel)
            }
            CPAUsageCollectionStatus(store: store)
        }
    }
}

/// 首页唯一的公共筛选入口。统计区不再嵌入时间、提供商、模型筛选控件，
/// 此处读取共享结果中的选项，不创建额外的 ViewModel、队列消费者或网络请求。
struct CPADashboardCommonFilters: View {
    let store: UsageStatisticsStore
    let model: CPAUsageDashboardViewModel
    @Binding var selection: CPAUsageSelection
    /// 切换筛选时查询模型会暂时清空 result；保留最近一次选项，防止提供商胶囊闪失。
    /// 这里只缓存显示项，不新增统计查询或磁盘存储，也不恢复过期结果中的数值。
    @State private var recentOptions: CPAUsageEventPage?

    var body: some View {
        @Bindable var controls = model
        CPAUsageFilterCard(selection: $selection, options: model.result?.summary ?? recentOptions,
                           dimension: $controls.dimension, metric: $controls.metric,
                           isAvailable: store.legacyTotals == nil,
                           loadOptions: { try await store.queryFilterOptions() }) { draft in
            // 三份现有状态在同一个同步 SwiftUI 事务内提交；没有 await 或额外刷新调用，
            // 下游 task(id:) 只接收本次应用完成后的完整查询，草稿输入不会逐项触发请求。
            withTransaction(Transaction()) {
                selection = draft.selection
                controls.dimension = draft.dimension
                controls.metric = draft.metric
            }
        }
        .onChange(of: optionsIdentity, initial: true) {
            if let options = model.result?.summary { recentOptions = options }
        }
    }

    private var optionsIdentity: [[CPAUsageFilterChoice]]? {
        guard let options = model.result?.summary else { return nil }
        return [options.providers, options.models, options.sources, options.apiKeys].map { values in
            values.map { CPAUsageFilterChoice(id: $0.id, title: $0.title) }
        }
    }
}

/// 高频事件更新合并到五秒查询周期；窗口不活跃及 push 离开时由 SwiftUI 取消任务。
/// 每分钟仍重算滚动时间窗，使没有新请求时 RPM/TPM 与时间筛选也能正确推进。
private struct CPAUsageDashboardContent: View {
    let store: UsageStatisticsStore
    @Binding var selection: CPAUsageSelection
    let totalAccounts: Int
    let readyAccounts: Int
    @Environment(\.scenePhase) private var scenePhase
    let model: CPAUsageDashboardViewModel
    @State private var limit = 8

    private var query: CPAUsageDashboardViewModel.Query {
        .init(selection: selection, dimension: model.dimension, metric: model.metric, limit: limit, active: scenePhase == .active)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            if let result = model.result {
                CPAUsageOverviewSection(metrics: result.summary.metrics,
                                        totalAccounts: totalAccounts, readyAccounts: readyAccounts,
                                        isIncomplete: result.omittedHistoricalRequests > 0,
                                        historicalRequests: result.historicalRequests)
                VStack(alignment: .leading, spacing: 14) {
                    Text("usage.dashboard.analysis".localized()).font(.headline)
                    // 趋势和排行直接展示，不再在外层折叠卡片内嵌套一组图表卡片。
                    CPAUsageTrendChart(points: result.trend, hourly: result.hourly, metric: model.metric)
                    CPAUsageDistributionChart(report: result, selection: selection, dimension: model.dimension,
                                              metric: model.metric, limit: $limit)
                }
                if let date = result.summary.collectionStartedAt {
                    Text("usage.records.startedAt".localized() + " " + date.formatted(date: .abbreviated, time: .shortened))
                        .font(.caption).foregroundStyle(.secondary).monospacedDigit()
                }
            } else if model.errorKey == nil {
                // 仅首次加载或更换查询口径时显示占位，同条件后台更新不清空现有图表。
                ProgressView("usage.status.loading".localized()).frame(maxWidth: .infinity, minHeight: 260)
            }
            if let key = model.errorKey {
                Label(key.localized(), systemImage: "exclamationmark.triangle")
                    .font(.caption).foregroundStyle(QuotioTheme.Colors.warning)
            }
        }
        .task(id: query) {
            let request = query
            guard request.active else { return }
            var lastRevision: Int?
            var lastMinute: Int?
            while !Task.isCancelled {
                let revision = store.statisticsRevision
                let minute = Int(Date().timeIntervalSince1970 / 60)
                if revision != lastRevision || minute != lastMinute {
                    if await model.load(request, store: store) {
                        lastRevision = revision; lastMinute = minute
                    }
                }
                do { try await Task.sleep(for: .seconds(5)) } catch { return }
            }
        }
        .onChange(of: selection) { _, _ in limit = 8 }
        .onChange(of: model.dimension) { _, _ in limit = 8 }
    }
}

/// 趋势标题、静态图形及悬停交互拆成独立视图，避免一个鼠标事件重建整套 ChartContent。
private struct CPAUsageTrendChart: View {
    let points: [CPAUsageTrendPoint]
    let hourly: Bool
    let metric: CPAUsageChartMetric

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack {
                Text("usage.dashboard.trend".localized()).font(.subheadline.weight(.semibold))
                Spacer()
                Text(metric.titleKey.localized()).font(.caption).foregroundStyle(.secondary)
            }
            if points.isEmpty {
                ContentUnavailableView("usage.empty.title".localized(), systemImage: "chart.xyaxis.line",
                    description: Text("usage.records.empty".localized())).frame(height: 190)
            } else {
                CPAUsageTrendPlot(points: points, metric: metric, hourly: hourly)
                    .frame(height: 190)
            }
            Text("usage.dashboard.trendNote".localized()).font(.caption2).foregroundStyle(.secondary)
        }.quotioCard()
    }
}

/// 图表本体只依赖有界采样点和指标，不持有鼠标状态，不动态插入 RuleMark 或 annotation。
/// 固定数值域，避免提示内容改变坐标范围后再次触发悬停/布局反馈。
private struct CPAUsageTrendPlot: View {
    let points: [CPAUsageTrendPoint]
    let metric: CPAUsageChartMetric
    let hourly: Bool

    private func value(_ point: CPAUsageTrendPoint) -> Int { metric == .tokens ? point.tokens : point.requests }

    var body: some View {
        let maximum = max(1, points.map { value($0) }.max() ?? 0)
        Chart(points) { point in
            // 使用单一稳定的折线标记，去掉每个点内的条件标记和重复面积系列。
            LineMark(x: .value("Time", point.date), y: .value("Usage", value(point)))
                .foregroundStyle(QuotioTheme.Colors.info)
                .lineStyle(StrokeStyle(lineWidth: 2))
                .symbol(.circle).symbolSize(points.count == 1 ? 20 : 0)
        }
        .chartYScale(domain: 0...maximum)
        .chartYAxis {
            AxisMarks(position: .leading, values: .automatic(desiredCount: 4)) { mark in
                AxisGridLine()
                AxisValueLabel { if let count = mark.as(Int.self) { Text(count.formattedCompact).monospacedDigit() } }
            }
        }
        .chartXAxis { AxisMarks(values: .automatic(desiredCount: 6)) }
        .chartOverlay { proxy in
            CPAUsageTrendHover(points: points, metric: metric, hourly: hourly, proxy: proxy)
        }
        .transaction { $0.animation = nil }
    }
}

/// 提示在图表覆盖层单独更新，不参与坐标轴或父容器尺寸计算。
/// 只有命中不同的数据点才写 State，光标在同一区间移动不会反复触发视图更新。
private struct CPAUsageTrendHover: View {
    let points: [CPAUsageTrendPoint]
    let metric: CPAUsageChartMetric
    let hourly: Bool
    let proxy: ChartProxy
    @State private var selectedDate: Date?

    var body: some View {
        GeometryReader { geometry in
            ZStack(alignment: .topLeading) {
                Rectangle().fill(.clear).contentShape(Rectangle())
                    .onContinuousHover { phase in
                        switch phase {
                        case .active(let location):
                            guard let anchor = proxy.plotFrame else { clearSelection(); return }
                            let plot = geometry[anchor]
                            guard plot.contains(location),
                                  let date = proxy.value(atX: location.x - plot.minX, as: Date.self) else {
                                clearSelection(); return
                            }
                            let nearest = points.min { abs($0.date.timeIntervalSince(date)) < abs($1.date.timeIntervalSince(date)) }?.date
                            if selectedDate != nearest { selectedDate = nearest }
                        case .ended: clearSelection()
                        }
                    }
                if let selectedDate, let point = points.first(where: { $0.date == selectedDate }) {
                    VStack(alignment: .leading, spacing: 3) {
                        Text(point.date.formatted(date: .abbreviated, time: hourly ? .shortened : .omitted))
                        Text((metric == .tokens ? point.tokens : point.requests).formatted() + " " + metric.titleKey.localized())
                            .monospacedDigit()
                    }
                    .font(.caption).padding(8)
                    .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 8))
                    .padding(.leading, 44).padding(.top, 4)
                    .allowsHitTesting(false)
                }
            }
        }
    }

    private func clearSelection() {
        if selectedDate != nil { selectedDate = nil }
    }
}

/// 名称、数值与百分比为固定列，条形图使用剩余最大宽度；显示更多采用有界增量查询。
private struct CPAUsageDistributionChart: View {
    let report: CPAUsageDashboardReport
    let selection: CPAUsageSelection
    let dimension: CPAUsageDimension
    let metric: CPAUsageChartMetric
    @Binding var limit: Int
    @Environment(\.colorScheme) private var colorScheme

    private var total: Int { metric == .tokens ? report.summary.metrics.tokens : report.summary.metrics.requests }
    private var maximum: Int { report.categories.first?.value(metric) ?? 0 }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack {
                Text("usage.dashboard.distribution".localized()).font(.subheadline.weight(.semibold))
                Spacer(minLength: 8)
                Text("usage.dashboard.clickForRecords".localized()).font(.caption2).foregroundStyle(.secondary)
            }
            if report.categories.isEmpty {
                ContentUnavailableView("usage.empty.title".localized(), systemImage: "chart.bar.xaxis")
                    .frame(minHeight: 160)
            } else {
                LazyVStack(spacing: 10) {
                    ForEach(report.categories) { item in
                        NavigationLink(value: CPAUsageDestination.records(item.selection(from: selection, dimension: dimension))) {
                            CPAUsageDistributionRow(item: item, value: item.value(metric), maximum: maximum,
                                                    total: total, tint: tint(item))
                        }.buttonStyle(.plain)
                    }
                }
            }
            HStack {
                if report.hasMoreCategories && limit < 1_000 {
                    Button("usage.dashboard.showMore".localized()) { limit = min(1_000, limit + 40) }
                        .buttonStyle(.quotioMicroCapsule)
                }
                if limit > 8 {
                    Button("usage.dashboard.topEight".localized()) { limit = 8 }.buttonStyle(.quotioMicroCapsule)
                }
                Spacer()
                NavigationLink(value: CPAUsageDestination.records(selection)) {
                    Label("usage.dashboard.records".localized(), systemImage: "chevron.right")
                }.buttonStyle(.quotioMicroCapsule)
            }
        }.quotioCard()
    }
    private func tint(_ row: CPAUsageCategory) -> Color {
        let provider = (dimension == .provider ? row.key : row.provider).lowercased()
        if provider == "claude" || provider == "anthropic" { return QuotioTheme.Colors.claudeUsage(for: colorScheme) }
        if provider == "codex" || provider == "openai" { return QuotioTheme.Colors.codexGreen }
        if provider == "opencode" { return QuotioTheme.Colors.opencodeBlue }
        // 稳定散列不使用随机 Hasher，不随数组位置或应用重启改变颜色。
        let colors = [QuotioTheme.Colors.info, QuotioTheme.Colors.success, QuotioTheme.Colors.warning, QuotioTheme.Colors.opencodeBlue]
        let index = row.id.utf8.reduce(UInt64(14695981039346656037)) { ($0 ^ UInt64($1)) &* 1099511628211 }
        return colors[Int(index % UInt64(colors.count))]
    }
}

private struct CPAUsageDistributionRow: View {
    let item: CPAUsageCategory
    let value: Int
    let maximum: Int
    let total: Int
    let tint: Color
    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        HStack(spacing: 10) {
            VStack(alignment: .leading, spacing: 3) {
                Text(item.title.isEmpty ? "usage.records.unknown".localized() : item.title)
                    .font(.system(size: 12, weight: .medium)).lineLimit(1).truncationMode(.middle)
                if !item.provider.isEmpty { Text(item.provider).font(.caption2).foregroundStyle(.secondary).lineLimit(1) }
            }.frame(width: 156, alignment: .leading).help(item.title)
            GeometryReader { geometry in
                Capsule().fill(QuotioTheme.Colors.cardInset(for: colorScheme))
                    .overlay(alignment: .leading) {
                        Capsule().fill(tint)
                            .frame(width: maximum > 0 ? geometry.size.width * min(1, Double(value) / Double(maximum)) : 0)
                    }
            }.frame(minWidth: 50, maxWidth: .infinity).frame(height: 8).accessibilityHidden(true)
            Text(value.formattedCompact).font(.callout.monospacedDigit()).frame(width: 76, alignment: .trailing)
                .help(value.formatted())
            Text(total > 0 ? Double(value) / Double(total) : 0, format: .percent.precision(.fractionLength(1)))
                .font(.caption.monospacedDigit()).foregroundStyle(.secondary).frame(width: 52, alignment: .trailing)
        }
        .padding(.vertical, 3).contentShape(Rectangle()).accessibilityElement(children: .combine)
    }
}

private struct CPALegacyUsageOverview: View {
    let totals: UsageTotals
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Label("usage.cpa.legacyScope".localized(), systemImage: "info.circle").font(.caption)
            UsageStatisticsSummary(totals: totals, available: true, modelCount: nil,
                unavailableMetrics: ["usage.inputTokens", "usage.outputTokens", "usage.cachedTokens", "usage.reasoningTokens"])
            Text("usage.cpa.requests".localized() + ": " + totals.requests.formatted()).monospacedDigit()
        }
    }
}

/// 后台轮询不插入和移除进度圈；启用操作与真实采集状态仍然即时可见。
private struct CPAUsageCollectionStatus: View {
    let store: UsageStatisticsStore
    @State private var isEnabling = false
    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                Label(store.statusKey.localized(), systemImage: store.state == .live ? "checkmark.circle" : "info.circle")
                Spacer()
                if store.state == .disabled {
                    Button("usage.enable".localized()) {
                        guard !isEnabling else { return }
                        isEnabling = true
                        Task { await store.enableCollection(); isEnabling = false }
                    }.buttonStyle(.quotioMicroCapsule).disabled(isEnabling)
                }
            }
            CPAUsageCollectionTimestamp(store: store)
            Text("usage.dashboard.coverage".localized())
        }.font(.caption).foregroundStyle(.secondary)
    }
}

/// 秒级心跳只重绘这一行，不使统计图表或导航按钮重新求值。
private struct CPAUsageCollectionTimestamp: View {
    let store: UsageStatisticsStore
    var body: some View {
        if let date = store.snapshot.lastCollectedAt {
            Text("usage.cpa.collectedAt".localized() + " " + date.formatted(date: .abbreviated, time: .standard))
                .monospacedDigit().contentTransition(.identity).transaction { $0.animation = nil }
        }
    }
}
