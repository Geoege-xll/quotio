// Copyright 2026 AIUsage contributors
// SPDX-License-Identifier: Apache-2.0
// 客户端调用分析页面：仅保留本地工具调用（Tool / MCP / Skill / Subagent）统计，
// 已按用户要求彻底移除所有本地会话 Token 卡片、Token 折线趋势、Token 热力图及模型 Token 分布。
import SwiftUI

struct CallAnalyticsScreen: View {
    @Environment(\.colorScheme) private var colorScheme
    let viewModel: CallAnalyticsViewModel
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

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                controlDeck
                if let error = viewModel.errorMessage {
                    Label(error, systemImage: "exclamationmark.triangle")
                        .font(.caption).foregroundStyle(.orange).accessibilityElement(children: .combine)
                }

                sectionContent(now: Date())

                collectionDetailsSection
            }
            .padding(20)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
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
        }
        .onDisappear {
            viewModel.setPageActive(false)
        }
        .onChange(of: scopeRaw) { applyFilters(); expandedServers.removeAll() }
        .onChange(of: rangeRaw) { applyFilters() }
        .onChange(of: customStartTS) { applyFilters() }
        .onChange(of: customEndTS) { applyFilters() }
    }

    /// 来源与时间是整页共用的筛选条件。
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

    /// 共用同一份来源／时间过滤结果，展示工具调用概览、每日调用趋势、排行榜与未使用清单。
    @ViewBuilder
    private func sectionContent(now: Date) -> some View {
        ClientAnalyticsOverview(calls: derived)
        if !viewModel.report.canDisplayTotals && !viewModel.isLoading {
            emptyState
        } else {
            let bounds = range.bounds(now: now, start: customStart, end: customEnd)
            ClientAnalyticsDailyTrend(
                data: ClientAnalyticsDailyTrendData(
                    calls: viewModel.report.trend,
                    toolsAvailable: viewModel.report.canDisplayTotals,
                    lowerDay: bounds.0, upperDay: bounds.1, now: now),
                subtitle: range == .custom ? customRangeLabel : range.localizationKey.localized(),
                accent: scopeTint(scope))
            rankingCard
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
            if viewModel.isLoading {
                viewModel.cancel()
            } else {
                viewModel.refresh()
            }
        } label: {
            HStack(spacing: 6) {
                if viewModel.isLoading { ProgressView().controlSize(.small) }
                Label((viewModel.isLoading ? "callAnalytics.cancel" : "callReplica.rescan").localized(),
                      systemImage: viewModel.isLoading ? "xmark.circle" : "arrow.clockwise")
            }
        }
        .help((viewModel.isLoading ? "callAnalytics.cancel" : "callReplica.rescan").localized())
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

    private var collectionDetailsSection: some View {
        DisclosureGroup("analytics.collectionDetails".localized()) {
            VStack(alignment: .leading, spacing: 14) {
                sourceFooter
                if scope == .pi || scope == .all {
                    Text("callAnalytics.pi.coverage".localized()).font(.caption).foregroundStyle(.secondary)
                }
                Text("callAnalytics.aggregationTimeZone".localized() + " · " + viewModel.aggregationTimeZone.identifier)
                    .font(.caption2).foregroundStyle(.secondary)
            }
            .padding(.top, 10)
        }
        .font(.caption)
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
