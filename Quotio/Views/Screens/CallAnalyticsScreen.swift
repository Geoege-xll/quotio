// Copyright 2026 AIUsage contributors
// SPDX-License-Identifier: Apache-2.0
// 移植 AIUsage CallAnalyticsView 的完整页面布局与交互；Quotio 使用现有 Observation/本地统计引擎。
import SwiftUI

struct CallAnalyticsScreen: View {
    @Environment(\.colorScheme) private var colorScheme
    let viewModel: CallAnalyticsViewModel
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
    private var isSingleDay: Bool { range == .today || (range == .custom && Calendar.current.isDate(customStart, inSameDayAs: customEnd)) }
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
                kpiStrip
                if !viewModel.report.canDisplayTotals && !viewModel.isLoading {
                    emptyState
                } else {
                    if !isSingleDay { trendCard }
                    rankingCard
                    zeroCallCard
                }
                // 会话统计独立于工具统计：没有工具事件的纯文本子代理也应显示。
                if !derived.agents.isEmpty { agentCard }
                if derived.report.hasUndatedAgentInvocations {
                    Text("callReplica.agent.unknownDate".localized()).font(.caption).foregroundStyle(.secondary)
                }
                if scope == .pi || scope == .all {
                    Text("callAnalytics.pi.coverage".localized()).font(.caption).foregroundStyle(.secondary)
                }
                sourceFooter
                // 明确日摘要采用的固定时区，使旅行或系统改区后的日期口径可见。
                Text("callAnalytics.aggregationTimeZone".localized() + " · " + viewModel.aggregationTimeZone.identifier)
                    .font(.caption2).foregroundStyle(.secondary)
            }
            .padding(20)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .analyticsPageChrome(colorScheme)
        .navigationTitle("nav.callAnalytics".localized())
        // 扫描是整页操作，使用系统导航工具栏；扫描中保留取消而不是重复启动。
        .toolbar { ToolbarItem(placement: .primaryAction) { scanButton } }
        // 页面重建只恢复筛选与检查新鲜度；已有扫描由主界面的常驻模型继续持有。
        .onAppear { applyFilters(); viewModel.refreshIfNeeded() }
        // 维护期间短暂进入又离开，不应在清理完成后重新启动一个用户已离开的页面扫描。
        .onDisappear { viewModel.discardPendingMaintenanceRefresh() }
        .onChange(of: scopeRaw) { applyFilters(); expandedServers.removeAll() }
        .onChange(of: rangeRaw) { applyFilters() }
        .onChange(of: customStartTS) { applyFilters() }
        .onChange(of: customEndTS) { applyFilters() }
    }

    /// 顶部固定两行：第一行来源，第二行时间范围与自定义起止；切换范围仅重新派生本地摘要。
    private var controlDeck: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 12) {
                cluster("callReplica.source", icon: "square.stack.3d.up") {
                    // 窄窗口仍保持固定两行，来源分段可横向滚动，避免长文案与扫描按钮重叠。
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

            }
            cluster("callAnalytics.range", icon: "calendar") {
                // 时间范围和自定义起止共用一行；窄窗口横向滚动，避免日期控件另起一行。
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

    /// 起止控件沿用现有日期文案与弹出层，嵌入范围行后仍保留独立的操作入口。
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
            if viewModel.isLoading { viewModel.cancel() } else { viewModel.refresh() }
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

    private var kpiStrip: some View {
        LazyVGrid(columns: [GridItem(.adaptive(minimum: 150), spacing: 12)], spacing: 12) {
            kpi("callReplica.total", count: derived.report.totalCalls, icon: "wrench.and.screwdriver", tint: .indigo)
            kpi("callReplica.mcpCalls", count: derived.mcpCalls, icon: "puzzlepiece.extension", tint: .purple)
            kpi("callReplica.skillCalls", count: derived.skillCalls, icon: "sparkles", tint: .pink)
            kpi("callReplica.activeMCP", count: derived.activeServers, icon: "server.rack", tint: .blue)
            kpi("callReplica.unusedSkills", count: derived.unusedSkills, icon: "moon.zzz", tint: .orange, available: !derived.report.hasReadFailures)
        }
    }

    private func kpi(_ key: String, count: Int, icon: String, tint: Color, available: Bool = true) -> some View {
        HStack(spacing: 10) {
            Image(systemName: icon)
                .font(.system(size: 15, weight: .semibold))
                .foregroundStyle(tint)
                .frame(width: 32, height: 32)
                .background(tint.opacity(0.12), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
            VStack(alignment: .leading, spacing: 2) {
                Text(key.localized())
                    .font(.caption2.weight(.medium))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .minimumScaleFactor(0.85)
                Text(derived.report.canDisplayTotals && available ? count.formatted() : "—")
                    .font(.system(size: 18, weight: .bold, design: .rounded))
                    .foregroundStyle(tint)
                    .monospacedDigit()
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .quotioCard(cornerRadius: QuotioTheme.Radius.md, padding: 12)
        .accessibilityElement(children: .combine)
    }

    private var trendCard: some View {
        card("callAnalytics.dailyTrend", subtitle: range == .custom ? customRangeLabel : range.localizationKey.localized()) {
            if derived.report.trend.isEmpty {
                Text("callAnalytics.empty.title".localized()).font(.caption).foregroundStyle(.tertiary)
            } else {
                CallReplicaTrendBars(points: derived.report.trend).frame(height: 72)
            }
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
        // 扫描数来自最新读取，调用数来自当前时间范围；OpenCode 的单位为数据库，不伪称会话文件。
        let (lower, upper) = range.bounds(now: Date(), start: customStart, end: customEnd)
        // 页脚列出全部来源，不能套用顶部单应用过滤后把其它应用的真实调用显示成 0。
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
