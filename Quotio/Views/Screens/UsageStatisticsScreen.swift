// Copyright 2026 AIUsage contributors. Licensed under Apache-2.0.
// 参考 ProxyStatsView（bdb83bbe）；修改：接入三个客户端的本地Token账本，不与CPA事件混加。
import SwiftUI

/// 本地用量独立于仪表盘 CPA 统计，不提供跨账本切换，避免口径混淆。
struct UsageStatisticsScreen: View {
    let clientUsage: ClientUsageViewModel
    @Environment(\.colorScheme) private var colorScheme
    @AppStorage("usageStatistics.period") private var period: UsageStatisticsPeriod = .all
    @AppStorage("usageStatistics.clientSource") private var sourceID = "all"
    @State private var hoverState = UsageHeatmapHoverState()

    private var options: [ClientUsageSource?] { [nil] + ClientUsageSource.allCases.map(Optional.some) }
    private var source: ClientUsageSource? { ClientUsageSource(rawValue: sourceID) }
    private var sourceBinding: Binding<ClientUsageSource?> {
        Binding(get: { source }, set: { sourceID = $0?.rawValue ?? "all" })
    }

    var body: some View {
        GeometryReader { viewport in
            // 午夜更新本地期间边界；客户端日志导入与CPA采集各自独立。
            TimelineView(.periodic(from: .now, by: 60)) { context in
                content(now: context.date, width: viewport.size.width - 40)
            }
            .overlay(alignment: .topLeading) {
                UsageHeatmapOverlay(state: hoverState, viewportSize: viewport.size)
            }
        }
        .coordinateSpace(.named("usageHeatmapPage"))
        .analyticsPageChrome(colorScheme)
        .navigationTitle("usage.title".localized())
        // 刷新属于整页操作，放入系统导航工具栏；扫描期间仍提供原有取消能力。
        .toolbar { ToolbarItem { refreshButton } }
        .task { clientUsage.start() }
        .onDisappear { clientUsage.stopAutomaticRefresh(); hoverState.selection = nil }
        .onReceive(NotificationCenter.default.publisher(for: .NSSystemTimeZoneDidChange)) { _ in
            clientUsage.reloadPresentation(); hoverState.selection = nil
        }
        .onReceive(NotificationCenter.default.publisher(for: NSLocale.currentLocaleDidChangeNotification)) { _ in
            clientUsage.reloadPresentation(); hoverState.selection = nil
        }
        .onChange(of: sourceID) { _, _ in hoverState.selection = nil }
        .onChange(of: period) { _, _ in hoverState.selection = nil }
    }

    private func content(now: Date, width: CGFloat) -> some View {
        let interval = period.interval(now: now, start: now, end: now, calendar: .current)
        let display = clientUsage.presentation(interval: interval, source: source)
        let presentation = display.statistics
        let history = clientUsage.presentation(interval: nil, source: source).statistics
        let available = display.available
        let lacksReasoning = display.lacksReasoning
        return ScrollView {
            LazyVStack(alignment: .leading, spacing: 16) {
                controlDeck
                UsageStatisticsSummary(totals: presentation.totals, available: available,
                                       modelCount: presentation.models.count,
                                       unavailableMetrics: lacksReasoning ? ["usage.reasoningTokens"] : [])
                if lacksReasoning {
                    Text("usage.pi.reasoningUnavailable".localized()).font(.caption).foregroundStyle(.secondary)
                }
                if available {
                    dataRange(history: history)
                    heatmaps(history: history, now: now, width: width)
                    if presentation.buckets.isEmpty {
                        emptyState
                    } else {
                        UsageStatisticsTrend(days: presentation.days, accent: sourceTint(source))
                        UsageStatisticsInsights(presentation: presentation, contentWidth: max(0, width))
                    }
                } else {
                    emptyState
                }
                collectionStatus
                Text("usage.client.retention".localized()).font(.caption2).foregroundStyle(.secondary)
            }
            .padding(20)
        }
    }

    /// 顶部筛选固定两行：第一行来源，第二行视图/时间范围，宽窗口也不合并，保持阅读顺序稳定。
    /// 默认「综合、全部」及各来源偏好继续跨重启保留；窄窗口内各行仍可独立横向滚动。
    private var controlDeck: some View {
        VStack(alignment: .leading, spacing: 9) {
            sourceControls
            viewControls
        }
        .padding(.horizontal, 14).padding(.vertical, 12)
        .modifier(UsageAnalyticsSurface())
    }
    private var sourceControls: some View {
        HStack(spacing: 9) {
            clusterLabel("usage.replica.source", symbol: "square.stack.3d.up")
            ScrollView(.horizontal) {
                QuotioCapsuleSegmentedControl(
                    options,
                    selection: sourceBinding,
                    size: .medium,
                    optionTint: { source in sourceTint(source) },
                    isEqualWidth: false,
                    icon: { source in sourceIcon(source) },
                    title: { source in sourceTitle(source) }
                )
            }.scrollIndicators(.hidden)
        }
        .frame(minWidth: 180)
    }
    private var viewControls: some View {
        HStack(spacing: 9) {
            clusterLabel("usage.replica.view", symbol: "slider.horizontal.3")
            ScrollView(.horizontal) {
                // 视图行只保留期间筛选，删除固定单位标签与旁侧说明图标，减少视觉干扰。
                QuotioCapsuleSegmentedControl(
                    periodOptions,
                    selection: $period,
                    size: .medium,
                    optionTint: { _ in sourceTint(source) },
                    isEqualWidth: false,
                    title: { $0.titleKey.localized() }
                )
            }.scrollIndicators(.hidden)
        }
        .frame(maxWidth: 390)
    }
    private var refreshButton: some View {
        Button {
            if clientUsage.isLoading { clientUsage.cancelRefresh() }
            else { clientUsage.refresh() }
        } label: {
            Label((clientUsage.isLoading ? "usage.client.cancel" : "usage.refresh").localized(),
                  systemImage: clientUsage.isLoading ? "xmark.circle" : "arrow.clockwise")
        }
        .help((clientUsage.isLoading ? "usage.client.cancel" : "usage.refresh").localized())
    }
    private func clusterLabel(_ key: String, symbol: String) -> some View {
        Label(key.localized(), systemImage: symbol).font(.caption2.weight(.semibold))
            .foregroundStyle(.secondary).frame(width: 62, alignment: .leading)
    }
    private var periodOptions: [UsageStatisticsPeriod] {
        [.today, .week, .month, .all]
    }
    private func sourceTitle(_ item: ClientUsageSource?) -> String {
        item?.title ?? "usage.replica.combined".localized()
    }
    private func sourceIcon(_ item: ClientUsageSource?) -> String? {
        guard let item else { return "square.stack.3d.up" }
        switch item {
        case .claude: return "sparkles"
        case .codex: return "chevron.left.forwardslash.chevron.right"
        case .opencode: return "terminal"
        case .pi: return "terminal.fill"
        }
    }
    /// 来源选择器、热力图和日趋势共用同一套语义色，不再各自散列或按时间范围换色。
    private func sourceTint(_ item: ClientUsageSource?) -> Color {
        UsageStatisticsPalette.source(item?.title, scheme: colorScheme)
    }

    private func heatmaps(history: UsageStatisticsPresentation, now: Date, width: CGFloat) -> some View {
        let groups = Dictionary(grouping: history.buckets, by: \.provider)
        return ForEach(groups.keys.sorted(), id: \.self) { provider in
            UsageStatisticsHeatmap(title: provider.isEmpty ? "usage.unknownProvider".localized() : provider,
                presentation: UsageHeatmapPresentation(buckets: groups[provider] ?? [], now: now,
                                                       firstCollectedAt: (groups[provider] ?? []).map(\.day).min()),
                accent: UsageStatisticsPalette.source(provider, scheme: colorScheme),
                availableWidth: max(0, width), onHover: { hoverState.selection = $0 })
        }
    }
    @ViewBuilder private func dataRange(history: UsageStatisticsPresentation) -> some View {
        if let first = history.days.first?.day, let last = history.days.last?.day {
            Label(String(format: "usage.replica.dataRange".localized(),
                         first.formatted(date: .numeric, time: .omitted), last.formatted(date: .numeric, time: .omitted)),
                  systemImage: "info.circle")
                .font(.caption).foregroundStyle(.secondary)
                .padding(.horizontal, 12).padding(.vertical, 6)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(QuotioTheme.Colors.cardInset(for: colorScheme), in: RoundedRectangle(cornerRadius: QuotioTheme.Radius.md, style: .continuous))
        }
    }
    private var emptyState: some View {
        ContentUnavailableView((clientUsage.isLoading ? "usage.client.loadingTitle" : "usage.client.emptyTitle").localized(),
                               systemImage: "chart.line.uptrend.xyaxis",
                               description: Text((clientUsage.isLoading ? "usage.client.loadingDescription" : "usage.client.emptyDescription").localized()))
            .frame(maxWidth: .infinity).padding(.vertical, 20)
    }

    /// 缺失与读取失败分来源呈现；「综合」的部分数据不伪装成三个来源均成功。
    private var collectionStatus: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 6) {
                if clientUsage.isLoading { ProgressView().controlSize(.small) }
                Text((clientUsage.isLoading ? "usage.client.scanning" : "usage.client.localLedger").localized())
                Spacer()
                if let date = clientUsage.snapshot.collectedAt {
                    Text(date, format: .dateTime.year().month().day().hour().minute().second())
                }
            }
            if let key = clientUsage.errorKey {
                Label(key.localized(), systemImage: "exclamationmark.triangle").foregroundStyle(.orange)
            }
            ForEach(ClientUsageSource.allCases.filter { source == nil || $0 == source }) { item in
                sourceStatus(item)
            }
            // 读取成功仅说明正式会话可解析，不代表第三方扩展的独立转录已被计入。
            // 与调用分析保持可见的统计口径，避免把未保存为正式会话的扩展消耗误解为零。
            if source == .pi || (source == nil && clientUsage.snapshot.statuses.contains(where: { $0.source == .pi && $0.available })) {
                Text("usage.pi.coverage".localized())
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .font(.caption).foregroundStyle(.secondary)
        .padding(14)
        .modifier(UsageAnalyticsSurface())
    }

    /// 当前阶段、文件进度和已完成来源同时可见，不再用单条无限旋转文案遮住所有结果。
    private func sourceStatus(_ source: ClientUsageSource) -> some View {
        let status = clientUsage.snapshot.statuses.first { $0.source == source }
        let activity = clientUsage.activities[source]
        let busy = activity?.phase == .queued || activity?.phase == .scanning || activity?.phase == .saving
        return VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 8) {
                if busy { ProgressView().controlSize(.mini) }
                else {
                    Circle().fill(status?.hasErrors == true ? .orange : (status?.available == true ? .green : .gray))
                        .frame(width: 6, height: 6)
                }
                Text(source.title)
                Text(sourceStatusKey(activity: activity, status: status).localized()).foregroundStyle(.secondary)
                Spacer()
                if let progress = activity?.progress, progress.filesTotal > 0 {
                    Text(String(format: "usage.client.fileProgress".localized(), progress.filesCompleted, progress.filesTotal))
                        .monospacedDigit()
                }
            }
            if busy, let progress = activity?.progress, progress.bytesTotal > 0 {
                HStack {
                    ProgressView(value: min(Double(progress.bytesRead), Double(progress.bytesTotal)), total: Double(progress.bytesTotal))
                        .frame(maxWidth: 180)
                    Text(ByteCountFormatter.string(fromByteCount: progress.bytesRead, countStyle: .file))
                        .monospacedDigit()
                }
            }
            if let reused = activity?.progress.filesReused, reused > 0 {
                Text(String(format: "usage.client.reused".localized(), reused)).foregroundStyle(.secondary)
            }
        }.accessibilityElement(children: .combine)
    }

    private func sourceStatusKey(activity: ClientUsageActivity?, status: ClientUsageStatus?) -> String {
        switch activity?.phase {
        case .queued: return "usage.client.queued"
        case .scanning: return "usage.client.scanning"
        case .saving: return "usage.client.saving"
        case .cancelled: return "usage.client.cancelledShort"
        case .failed: return "usage.client.readFailed"
        default:
            guard let status else { return "usage.client.queued" }
            return status.hasErrors ? "usage.client.readFailed" : (status.available ? "usage.client.readable" : "usage.client.missing")
        }
    }

}
