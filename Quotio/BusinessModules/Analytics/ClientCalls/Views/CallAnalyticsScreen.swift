// Copyright 2026 AIUsage contributors
// SPDX-License-Identifier: Apache-2.0
// 合并本地客户端用量（Token账本）与调用分析（工具/MCP/Skill），统一本地日志扫描与视图呈现。
import SwiftUI

struct CallAnalyticsScreen: View {
    @Environment(\.colorScheme) private var colorScheme
    let viewModel: CallAnalyticsViewModel
    var clientUsage: ClientUsageViewModel? = nil
    /// Tab 隐藏时视图继续保留滚动和展开状态，但不再扫描本地会话。
    var isActive = true
    @AppStorage("callAnalytics.ui.range") private var rangeRaw = CallAnalyticsDateRange.month.rawValue
    @AppStorage("callAnalytics.ui.scope") private var scopeRaw = CallReplicaScope.all.rawValue
    @AppStorage("callAnalytics.ui.customStart") private var customStartTS: Double = 0
    @AppStorage("callAnalytics.ui.customEnd") private var customEndTS: Double = 0
    @State private var lens = CallReplicaLens.mcp
    @State private var expandedServers = Set<String>()
    @State private var showCustomPopover = false
    @State private var showSourceHelp = false
    @State private var hoverState = UsageHeatmapHoverState()

    private var scope: CallReplicaScope { CallReplicaScope(rawValue: scopeRaw) ?? .all }
    private var range: CallAnalyticsDateRange { CallAnalyticsDateRange(rawValue: rangeRaw) ?? .month }
    private var derived: CallReplicaDerived { CallReplicaDerived(report: viewModel.report, snapshot: viewModel.snapshot, source: scope.source) }
    private var rawCustomStart: Date { customStartTS > 0 ? Date(timeIntervalSince1970: customStartTS) : Calendar.current.date(byAdding: .day, value: -6, to: Calendar.current.startOfDay(for: Date())) ?? Date() }
    private var rawCustomEnd: Date { customEndTS > 0 ? Date(timeIntervalSince1970: customEndTS) : Calendar.current.startOfDay(for: Date()) }
    // 历史偏好可能反向或位于未来，控件与摘要统一归一成 start ≤ end ≤ today。
    private var customStart: Date { min(min(rawCustomStart, rawCustomEnd), Date()) }
    private var customEnd: Date { min(max(rawCustomStart, rawCustomEnd), Date()) }
    private var scopeBinding: Binding<CallReplicaScope> { Binding(get: { scope }, set: { scopeRaw = $0.rawValue }) }
    private var rangeBinding: Binding<CallAnalyticsDateRange> { Binding(get: { range }, set: { rangeRaw = $0.rawValue }) }

    private func clientDisplay(now: Date) -> ClientUsageViewModel.Presentation? {
        guard let clientUsage else { return nil }
        let interval = range.usagePeriod.interval(now: now, start: customStart, end: customEnd, calendar: .current)
        return clientUsage.presentation(interval: interval, source: scope.clientUsageSource)
    }

    private func clientHistory() -> ClientUsageViewModel.Presentation? {
        guard let clientUsage else { return nil }
        return clientUsage.presentation(interval: nil, source: scope.clientUsageSource)
    }

    private var isAnyLoading: Bool {
        viewModel.isLoading || (clientUsage?.isLoading ?? false)
    }

    var body: some View {
        GeometryReader { viewport in
            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    controlDeck
                    if let error = viewModel.errorMessage {
                        Label(error, systemImage: "exclamationmark.triangle")
                            .font(.caption).foregroundStyle(.orange).accessibilityElement(children: .combine)
                    }
                    if let errorKey = clientUsage?.errorKey {
                        Label(errorKey.localized(), systemImage: "exclamationmark.triangle")
                            .font(.caption).foregroundStyle(.orange).accessibilityElement(children: .combine)
                    }

                    sectionContent(now: Date(), width: viewport.size.width - 40)

                    collectionDetailsSection
                }
                .padding(20)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .overlay(alignment: .topLeading) {
                UsageHeatmapOverlay(state: hoverState, viewportSize: viewport.size)
            }
        }
        .coordinateSpace(.named("usageHeatmapPage"))
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .analyticsPageChrome(colorScheme)
        // 扫描是整页操作，使用系统导航工具栏；扫描中保留取消而不是重复启动。
        .toolbar {
            if isActive { ToolbarItem(placement: .primaryAction) { scanButton } }
        }
        .onAppear {
            applyFilters()
        }
        .onChange(of: isActive, initial: true) { _, active in
            viewModel.setPageActive(active)
            clientUsage?.setPageActive(active)
            if !active { hoverState.selection = nil }
        }
        .onDisappear {
            viewModel.setPageActive(false)
            clientUsage?.setPageActive(false)
            hoverState.selection = nil
        }
        .onReceive(NotificationCenter.default.publisher(for: .NSSystemTimeZoneDidChange)) { _ in
            clientUsage?.reloadPresentation()
            hoverState.selection = nil
        }
        .onReceive(NotificationCenter.default.publisher(for: NSLocale.currentLocaleDidChangeNotification)) { _ in
            clientUsage?.reloadPresentation()
            hoverState.selection = nil
        }
        .onChange(of: scopeRaw) { applyFilters(); expandedServers.removeAll(); hoverState.selection = nil }
        .onChange(of: rangeRaw) { applyFilters(); hoverState.selection = nil }
        .onChange(of: customStartTS) { applyFilters(); hoverState.selection = nil }
        .onChange(of: customEndTS) { applyFilters(); hoverState.selection = nil }
    }

    /// 来源与时间是整页共用的筛选条件。统一看板始终展示 Token 与调用，取消旧的
    /// 整页维度切换；旧 clientAnalytics.ui.section 偏好保留在磁盘但不再隐藏任一模块。
    private var controlDeck: some View {
        VStack(alignment: .leading, spacing: 12) {
            cluster("callReplica.source", icon: "square.stack.3d.up") {
                ScrollView(.horizontal) {
                    QuotioCapsuleSegmentedControl(
                        CallReplicaScope.allCases,
                        selection: scopeBinding,
                        size: .medium,
                        optionTint: { scope in scopeTint(scope) },
                        isEqualWidth: false,
                        icon: { scopeIcon($0) },
                        title: { scopeTitle($0) }
                    )
                }
                .scrollIndicators(.hidden)
                .frame(height: 38)
            }
            cluster("callAnalytics.range", icon: "calendar") {
                ScrollView(.horizontal) {
                    HStack(spacing: 12) {
                        QuotioCapsuleSegmentedControl(
                            CallAnalyticsDateRange.allCases,
                            selection: rangeBinding,
                            size: .medium,
                            tint: .blue,
                            isEqualWidth: false,
                            title: { $0.localizationKey.localized() }
                        )
                        if range == .custom { customDateControls }
                    }
                }
                .scrollIndicators(.hidden)
                .frame(height: 38)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .quotioCard(cornerRadius: QuotioTheme.Radius.lg, padding: 14)
    }

    /// 共用同一份来源／时间过滤结果，先显示融合概览，再沿用完整综合分析内容。
    /// 合并发生在展示层，Token 和工具调用仍按各自的已有口径计算，不拼接原始账本。
    @ViewBuilder
    private func sectionContent(now: Date, width: CGFloat) -> some View {
        let display = clientDisplay(now: now)
        ClientAnalyticsOverview(client: display, calls: derived)
        if display?.lacksReasoning == true {
            Text("usage.pi.reasoningUnavailable".localized()).font(.caption).foregroundStyle(.secondary)
        }
        if !viewModel.report.canDisplayTotals && !viewModel.isLoading && (display?.available != true) {
            emptyState
        } else {
            // 两份已筛选日汇总只在展示层对齐，使用调用筛选的包含结束日边界；
            // 单日也保留两个独立刻度，共享一个悬停日与完整明细，不增加切换控件。
            let bounds = range.bounds(now: now, start: customStart, end: customEnd)
            ClientAnalyticsDailyTrend(
                data: ClientAnalyticsDailyTrendData(tokenDays: display?.statistics.days ?? [],
                    tokensAvailable: display?.available == true, calls: viewModel.report.trend,
                    toolsAvailable: viewModel.report.canDisplayTotals,
                    lowerDay: bounds.0, upperDay: bounds.1, now: now),
                subtitle: range == .custom ? customRangeLabel : range.localizationKey.localized(),
                accent: scopeTint(scope))
            if let history = clientHistory(), history.available {
                dataRange(history: history.statistics)
                heatmaps(history: history.statistics, now: now, width: width)
            }
            rankingCard
            if let display, display.available, !display.statistics.buckets.isEmpty {
                UsageStatisticsInsights(presentation: display.statistics, contentWidth: max(0, width))
            }
            zeroCallCard
        }
        if !derived.agents.isEmpty { agentCard }
        if derived.report.hasUndatedAgentInvocations {
            Text("callReplica.agent.unknownDate".localized()).font(.caption).foregroundStyle(.secondary)
        }
    }

    private var customDateControls: some View {
        cluster("callReplica.dates", icon: "calendar.badge.clock") {
            Button { showCustomPopover.toggle() } label: {
                HStack(spacing: 6) {
                    Image(systemName: "calendar")
                        .font(.system(size: 11, weight: .medium))
                        .foregroundStyle(Color.accentColor)
                    Text(customRangeLabel)
                        .font(.system(size: 11, weight: .medium).monospacedDigit())
                    Image(systemName: "chevron.down")
                        .font(.system(size: 8, weight: .semibold))
                        .foregroundStyle(.secondary)
                }
                .padding(.horizontal, 12)
                .frame(height: 28)
                .background(QuotioTheme.Colors.cardInset(for: colorScheme), in: Capsule())
                .overlay(
                    Capsule()
                        .strokeBorder(
                            colorScheme == .dark ? Color.white.opacity(0.08) : Color.black.opacity(0.06),
                            lineWidth: 0.5
                        )
                )
            }
            .buttonStyle(.plain)
            .contentShape(Capsule())
            .popover(isPresented: $showCustomPopover, arrowEdge: .bottom) { customPopover }
        }
    }

    private var scanButton: some View {
        Button {
            if isAnyLoading {
                viewModel.cancel()
                clientUsage?.cancelRefresh()
            } else {
                viewModel.refresh()
                clientUsage?.refresh()
            }
        } label: {
            HStack(spacing: 6) {
                if isAnyLoading { ProgressView().controlSize(.small) }
                Label((isAnyLoading ? "callAnalytics.cancel" : "callReplica.rescan").localized(),
                      systemImage: isAnyLoading ? "xmark.circle" : "arrow.clockwise")
            }
        }
        .help((isAnyLoading ? "callAnalytics.cancel" : "callReplica.rescan").localized())
        .accessibilityIdentifier("callAnalyticsScanButton")
    }

    private func cluster<Content: View>(_ key: String, icon: String, @ViewBuilder content: () -> Content) -> some View {
        HStack(spacing: 10) {
            Label(key.localized(), systemImage: icon).font(.caption2.weight(.semibold))
                .foregroundStyle(.secondary).frame(width: 70, alignment: .leading).fixedSize(horizontal: false, vertical: true)
            content()
        }
    }

    private var customRangeLabel: String {
        let start = min(customStart, customEnd), end = max(customStart, customEnd)
        let sameYear = Calendar.current.component(.year, from: start) == Calendar.current.component(.year, from: end)
        let style: Date.FormatStyle = sameYear ? .dateTime.month(.twoDigits).day(.twoDigits) : .dateTime.year().month(.twoDigits).day(.twoDigits)
        return start.formatted(style) + " → " + end.formatted(style)
    }

    private var customPopover: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("callReplica.quickRanges".localized()).font(.caption2.weight(.semibold)).foregroundStyle(.secondary)
            HStack(spacing: 6) {
                preset("callReplica.preset7") { setPreset(days: 7) }
                preset("callReplica.preset30") { setPreset(days: 30) }
                preset("callAnalytics.range.month") { setPreset(days: nil) }
            }
            Divider()
            DatePicker("callAnalytics.startDate".localized(), selection: Binding(get: { customStart }, set: { customStartTS = $0.timeIntervalSince1970 }), in: ...customEnd, displayedComponents: .date)
                .datePickerStyle(.field)
            DatePicker("callAnalytics.endDate".localized(), selection: Binding(get: { customEnd }, set: { customEndTS = $0.timeIntervalSince1970 }), in: min(customStart, Date())...Date(), displayedComponents: .date)
                .datePickerStyle(.field)
        }.padding(14).frame(width: 280)
    }

    private func preset(_ key: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(key.localized())
                .font(.caption.weight(.medium))
                .padding(.horizontal, 10)
                .padding(.vertical, 5)
                .background(QuotioTheme.Colors.cardInset(for: colorScheme), in: Capsule())
                .overlay(
                    Capsule()
                        .strokeBorder(
                            colorScheme == .dark ? Color.white.opacity(0.08) : Color.black.opacity(0.06),
                            lineWidth: 0.5
                        )
                )
        }.buttonStyle(.plain)
    }

    private func setPreset(days: Int?) {
        let today = Calendar.current.startOfDay(for: Date())
        let start = days.map { Calendar.current.date(byAdding: .day, value: -($0 - 1), to: today) ?? today }
            ?? Calendar.current.dateInterval(of: .month, for: today)?.start ?? today
        customStartTS = start.timeIntervalSince1970; customEndTS = today.timeIntervalSince1970
    }

    private func applyFilters() {
        viewModel.source = scope.source; viewModel.range = range; viewModel.kind = nil
        viewModel.customStart = customStart; viewModel.customEnd = customEnd
        if let clientUsage {
            let interval = range.usagePeriod.interval(now: Date(), start: customStart, end: customEnd, calendar: .current)
            _ = clientUsage.presentation(interval: interval, source: scope.clientUsageSource)
        }
    }

    private var rankingCard: some View {
        let rows = Array(derived.ranking(lens).prefix(12))
        return card("callReplica.rank." + lens.rawValue, subtitle: ("callReplica.rank." + lens.rawValue + ".description").localized()) {
            QuotioCapsuleSegmentedControl(
                CallReplicaLens.allCases,
                selection: $lens,
                size: .small,
                tint: .purple,
                isEqualWidth: false,
                icon: { lensIcon($0) },
                title: { ("callReplica.lens." + $0.rawValue).localized() }
            )
            .onChange(of: lens) { expandedServers.removeAll() }
            CallReplicaRankings(rows: rows, derived: derived, lens: lens, allSources: scope == .all, expandedServers: $expandedServers)
        }
    }

    private var agentCard: some View {
        card("callReplica.agent.title", subtitle: "callReplica.agent.description".localized()) {
            CallReplicaAgentBreakdown(rows: derived.agents)
        }
    }

    private var zeroCallCard: some View {
        card("callReplica.zero.title", subtitle: "callReplica.zero.description".localized()) {
            if derived.report.hasReadFailures || !derived.report.canDisplayTotals {
                Text("callAnalytics.unused.incomplete".localized()).font(.caption).foregroundStyle(.orange)
            }
            CallReplicaInventory(title: "callReplica.lens.skill".localized(), rows: derived.inventory(kind: .skill), emptyHint: "callReplica.skills.empty".localized())
            let servers = derived.inventory(kind: .mcp)
            if !servers.isEmpty {
                Divider().padding(.vertical, 4)
                CallReplicaInventory(title: "callReplica.servers".localized(), rows: servers, emptyHint: "")
            }
        }
    }

    private func heatmaps(history: UsageStatisticsPresentation, now: Date, width: CGFloat) -> some View {
        let groups = Dictionary(grouping: history.buckets, by: \.provider)
        return ForEach(groups.keys.sorted(), id: \.self) { provider in
            UsageStatisticsHeatmap(
                title: provider.isEmpty ? "usage.unknownProvider".localized() : provider,
                presentation: UsageHeatmapPresentation(
                    buckets: groups[provider] ?? [],
                    now: now,
                    firstCollectedAt: (groups[provider] ?? []).map(\.day).min()
                ),
                accent: UsageStatisticsPalette.source(provider, scheme: colorScheme),
                availableWidth: max(0, width),
                onHover: { hoverState.selection = $0 }
            )
        }
    }

    @ViewBuilder
    private func dataRange(history: UsageStatisticsPresentation) -> some View {
        if let first = history.days.first?.day, let last = history.days.last?.day {
            Label(
                String(format: "usage.replica.dataRange".localized(),
                       first.formatted(date: .numeric, time: .omitted),
                       last.formatted(date: .numeric, time: .omitted)),
                systemImage: "info.circle"
            )
            .font(.caption).foregroundStyle(.secondary)
            .padding(.horizontal, 12).padding(.vertical, 6)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(QuotioTheme.Colors.cardInset(for: colorScheme), in: RoundedRectangle(cornerRadius: QuotioTheme.Radius.md, style: .continuous))
        }
    }

    private var collectionDetailsSection: some View {
        DisclosureGroup("analytics.collectionDetails".localized()) {
            VStack(alignment: .leading, spacing: 14) {
                sourceFooter
                if let clientUsage {
                    Divider()
                    clientCollectionStatus(clientUsage)
                }
                if scope == .pi || scope == .all {
                    Text("callAnalytics.pi.coverage".localized()).font(.caption).foregroundStyle(.secondary)
                }
                Text("callAnalytics.aggregationTimeZone".localized() + " · " + viewModel.aggregationTimeZone.identifier)
                    .font(.caption2).foregroundStyle(.secondary)
                Text("usage.client.retention".localized())
                    .font(.caption2).foregroundStyle(.secondary)
            }
            .padding(.top, 10)
        }
        .font(.caption)
    }

    private func clientCollectionStatus(_ clientUsage: ClientUsageViewModel) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 6) {
                if clientUsage.isLoading { ProgressView().controlSize(.small) }
                Text((clientUsage.isLoading ? "usage.client.scanning" : "usage.client.localLedger").localized())
                    .font(.subheadline.weight(.semibold))
                Spacer()
                if let date = clientUsage.snapshot.collectedAt {
                    Text(date, format: .dateTime.year().month().day().hour().minute().second())
                        .font(.caption2.monospacedDigit())
                        .foregroundStyle(.tertiary)
                }
            }
            let activeSources = ClientUsageSource.allCases.filter { scope.clientUsageSource == nil || $0 == scope.clientUsageSource }
            ForEach(activeSources) { item in
                clientSourceRow(clientUsage: clientUsage, source: item)
            }
        }
    }

    private func clientSourceRow(clientUsage: ClientUsageViewModel, source: ClientUsageSource) -> some View {
        let status = clientUsage.snapshot.statuses.first { $0.source == source }
        let activity = clientUsage.activities[source]
        let busy = activity?.phase == .queued || activity?.phase == .scanning || activity?.phase == .saving
        return VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 8) {
                if busy {
                    ProgressView().controlSize(.mini)
                } else {
                    Circle().fill(status?.hasErrors == true ? Color.orange : (status?.available == true ? Color.green : Color.secondary.opacity(0.4)))
                        .frame(width: 7, height: 7)
                }
                Text(source.title)
                    .font(.caption.weight(.medium))
                Text(String(format: clientStatusKey(activity: activity, status: status).localized(),
                            Int64(status?.incompleteSessionCount ?? 0)))
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Spacer()
                if let progress = activity?.progress, progress.filesTotal > 0 {
                    Text(String(format: "usage.client.fileProgress".localized(), progress.filesCompleted, progress.filesTotal))
                        .font(.caption.monospacedDigit())
                }
            }
            if busy, let progress = activity?.progress, progress.bytesTotal > 0 {
                HStack {
                    ProgressView(value: min(Double(progress.bytesRead), Double(progress.bytesTotal)), total: Double(progress.bytesTotal))
                        .frame(maxWidth: 180)
                    Text(ByteCountFormatter.string(fromByteCount: progress.bytesRead, countStyle: .file))
                        .font(.caption2.monospacedDigit())
                }
            }
        }
        .accessibilityElement(children: .combine)
    }

    private func clientStatusKey(activity: ClientUsageActivity?, status: ClientUsageStatus?) -> String {
        switch activity?.phase {
        case .queued: return "usage.client.queued"
        case .scanning: return "usage.client.scanning"
        case .saving: return "usage.client.saving"
        case .cancelled: return "usage.client.cancelledShort"
        case .failed: return "usage.client.readFailed"
        default:
            guard let status else { return "usage.client.queued" }
            return status.readingStatusKey
        }
    }

    private var sourceFooter: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 8) {
                Text("callReplica.sources".localized())
                    .font(.subheadline.weight(.semibold))
                Text("callReplica.localLogs".localized())
                    .font(.caption2.weight(.medium))
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 7)
                    .padding(.vertical, 2.5)
                    .background(QuotioTheme.Colors.cardInset(for: colorScheme), in: Capsule())
                    .overlay(
                        Capsule()
                            .strokeBorder(
                                colorScheme == .dark ? Color.white.opacity(0.06) : Color.black.opacity(0.06),
                                lineWidth: 0.5
                            )
                    )
                Button { showSourceHelp.toggle() } label: {
                    Image(systemName: "questionmark.circle")
                        .font(.system(size: 13, weight: .semibold))
                        .frame(width: 22, height: 22)
                        .contentShape(Circle())
                }
                .buttonStyle(.plain)
                .foregroundStyle(.secondary)
                .help("callReplica.sourceHelp".localized())
                .accessibilityLabel("callReplica.sourceHelp".localized())
                .popover(isPresented: $showSourceHelp, arrowEdge: .top) { sourceHelp }
                Spacer()
            }
            VStack(alignment: .leading, spacing: 6) {
                ForEach(viewModel.snapshot.sources, id: \.source) { status in
                    let statusColor = status.errorCode != nil ? Color.red : (status.available ? Color.green : Color.secondary.opacity(0.4))
                    HStack(spacing: 8) {
                        Circle()
                            .fill(statusColor)
                            .frame(width: 7, height: 7)
                            .overlay(
                                Circle()
                                    .strokeBorder(statusColor.opacity(0.25), lineWidth: 1.5)
                                    .frame(width: 11, height: 11)
                            )
                        Text(status.source.displayName)
                            .font(.caption.weight(.medium))
                        Text(sourceDetail(status))
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    .accessibilityElement(children: .combine)
                }
            }
            if viewModel.snapshot.generatedAt != .distantPast {
                HStack(spacing: 4) {
                    Image(systemName: "clock.arrow.circlepath")
                        .font(.system(size: 10))
                    Text("callAnalytics.updated".localized() + " · " + viewModel.snapshot.generatedAt.formatted(.dateTime.month().day().hour().minute()))
                }
                .font(.caption2.monospacedDigit())
                .foregroundStyle(.tertiary)
                .padding(.top, 2)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .quotioCard(cornerRadius: QuotioTheme.Radius.lg, padding: 14)
    }

    private var sourceHelp: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("callReplica.sourceHelp".localized()).font(.headline)
            Text("callReplica.sourceDescription".localized()).font(.caption).foregroundStyle(.secondary)
            Divider()
            Text("callReplica.rulesDescription".localized()).font(.caption).foregroundStyle(.secondary)
            Text("callAnalytics.privacy".localized()).font(.caption).foregroundStyle(.secondary)
            Text("callAnalytics.heuristic".localized()).font(.caption).foregroundStyle(.secondary)
        }.fixedSize(horizontal: false, vertical: true).padding(16).frame(width: 350, alignment: .leading)
    }

    private func sourceDetail(_ status: CallSourceStatus) -> String {
        if status.errorCode != nil { return "callAnalytics.status.error".localized() }
        if !status.available { return "callAnalytics.status.absent".localized() }
        let (lower, upper) = range.bounds(now: Date(), start: customStart, end: customEnd)
        let calls = viewModel.snapshot.entries.filter {
            $0.source == status.source && (lower == nil || $0.dayKey >= lower!) && (upper == nil || $0.dayKey <= upper!)
        }.reduce(0) { $0 + $1.count }
        let key = status.source == .opencode ? "callReplica.sourceDatabaseCount" : "callReplica.sourceFileCount"
        return String(format: key.localized(), status.filesScanned, calls)
    }

    private var emptyState: some View {
        VStack(spacing: 10) {
            Image(systemName: "wrench.and.screwdriver").font(.system(size: 36)).foregroundStyle(.tertiary)
            Text("callAnalytics.unavailable.title".localized()).font(.callout).foregroundStyle(.secondary)
            Text("callAnalytics.unavailable.description".localized()).font(.caption).foregroundStyle(.tertiary)
        }.frame(maxWidth: .infinity).padding(.vertical, 48)
    }

    private func card<Content: View>(_ titleKey: String, subtitle: String? = nil, @ViewBuilder content: () -> Content) -> some View {
        AnalyticsCard {
            VStack(alignment: .leading, spacing: 12) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(titleKey.localized()).font(.headline)
                    if let subtitle { Text(subtitle).font(.caption).foregroundStyle(.secondary) }
                }
                content()
            }
        }
    }

    private func scopeTitle(_ scope: CallReplicaScope) -> String { scope.source?.displayName ?? "callReplica.all".localized() }

    private func scopeTint(_ scope: CallReplicaScope) -> Color {
        switch scope {
        case .all: return .indigo
        case .claude: return QuotioTheme.Colors.claudeOrange
        case .codex: return QuotioTheme.Colors.codexGreen
        case .opencode: return QuotioTheme.Colors.opencodeBlue
        case .pi: return CLIAgent.pi.color
        }
    }

    private func scopeIcon(_ scope: CallReplicaScope) -> String {
        switch scope {
        case .all: return "square.stack.3d.up"
        case .claude: return "sparkles"
        case .codex: return "chevron.left.forwardslash.chevron.right"
        case .opencode: return "terminal"
        case .pi: return "terminal.fill"
        }
    }

    private func lensIcon(_ lens: CallReplicaLens) -> String {
        switch lens {
        case .mcp: return "puzzlepiece.extension"
        case .skill: return "sparkles"
        case .tools: return "wrench.and.screwdriver"
        }
    }
}
