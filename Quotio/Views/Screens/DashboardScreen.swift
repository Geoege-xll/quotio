//
//  DashboardScreen.swift
//  Quotio
//

import SwiftUI
import UniformTypeIdentifiers

struct DashboardScreen: View {
    @Environment(QuotaViewModel.self) private var viewModel
    @Environment(\.colorScheme) private var colorScheme
    @AppStorage("hideGettingStarted") private var hideGettingStarted: Bool = false
    @State private var modeManager = OperatingModeManager.shared

    @State private var selectedProvider: AIProvider?
    @State private var isImporterPresented = false
    @State private var selectedAgentForConfig: CLIAgent?
    @State private var sheetPresentationID = UUID()
    /// 筛选由导航根页面持有，push 子页只接收快照，系统返回后保留首页上下文。
    // 首次展示全部已保存用量，旧日归档也能完整恢复；小时范围由用户显式选择。
    @State private var cpaSelection = CPAUsageSelection(range: .all)
    /// 首页只持有一份统计结果及筛选状态。筛选工具条与统计区分开观察，
    /// 聚合结果变化不会让顶部 CPA 卡片或导航栏跟着重新构造。
    @State private var cpaDashboardModel = CPAUsageDashboardViewModel()


    private var showGettingStarted: Bool {
        guard !hideGettingStarted else { return false }
        guard modeManager.isLocalProxyMode else { return false }
        return !isSetupComplete
    }

    private var isSetupComplete: Bool {
        viewModel.proxyManager.isBinaryInstalled &&
        viewModel.proxyManager.proxyStatus.running &&
        !viewModel.authFiles.isEmpty &&
        viewModel.agentSetupViewModel.agentStatuses.contains(where: { $0.configured })
    }

    /// Check if we should show main content
    private var shouldShowContent: Bool {
        if modeManager.isMonitorMode {
            return true // Always show content in quota-only mode
        }
        return viewModel.proxyManager.proxyStatus.running
    }

    // MARK: - Precomputed Properties (performance optimization)

    /// Unique provider count from direct auth files
    private var directProvidersCount: Int {
        Set(viewModel.monitorAccounts.map { $0.provider }).count
    }

    /// “最低额度”只取真实百分比额度的最低值，不平均独立额度池，也不将未知当成满额。
    private var lowestQuotaPercentage: Double? {
        QuotaPercentagePresentation.lowestRemaining(
            in: viewModel.providerQuotas.values.flatMap { $0.values }.flatMap(\.models)
        )
    }

    private var lowestQuotaColor: Color {
        guard let remaining = lowestQuotaPercentage else { return .secondary }
        return remaining > 50 ? QuotioTheme.Colors.success : (remaining > 20 ? QuotioTheme.Colors.warning : QuotioTheme.Colors.danger)
    }

    /// Grouped accounts by provider (cached computation)
    private var groupedMonitorAccounts: [AIProvider: [MonitorAccount]] {
        Dictionary(grouping: viewModel.monitorAccounts) { $0.provider }
    }

    var body: some View {
        ScrollViewReader { scrollProxy in
            ScrollView {
                VStack(alignment: .leading, spacing: 20) {
                    if modeManager.isLocalProxyMode {
                        fullModeContent(scrollProxy: scrollProxy)
                    } else {
                        // Quota-Only Mode: Show quota dashboard
                        quotaOnlyModeContent
                    }
                }
                .padding(24)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .quotioPage()
            .navigationTitle("nav.dashboard".localized())
            .navigationDestination(for: CPAUsageDestination.self) { destination in
                switch destination {
                case .records(let selection):
                    CPAUsageRecordsView(store: viewModel.usageMonitor, selection: selection)
                case .pricing(let selection):
                    CPAUsagePricingView(store: viewModel.usageMonitor, selection: selection)
                }
            }
            .toolbar {
                if modeManager.isLocalProxyMode {
                    ToolbarItem(placement: .primaryAction) {
                        NavigationLink(value: CPAUsageDestination.records(cpaSelection)) {
                            Label("usage.dashboard.records".localized(), systemImage: "list.bullet.rectangle")
                        }
                    }
                    ToolbarItem(placement: .primaryAction) {
                        NavigationLink(value: CPAUsageDestination.pricing(cpaSelection)) {
                            Label("usage.pricing.title".localized(), systemImage: "dollarsign.circle")
                        }
                    }
                }
                ToolbarItem(placement: .primaryAction) {
                    // 工具栏在独立观察边界内处理手动刷新，不订阅每两秒变化的后台采集状态。
                    DashboardRefreshButton()
                }
            }
            .sheet(item: $selectedProvider) { provider in
                OAuthSheet(provider: provider) {
                    selectedProvider = nil
                    viewModel.oauthState = nil
                    Task {
                        if modeManager.isMonitorMode {
                            await viewModel.manualRefresh()
                        } else {
                            await viewModel.refreshData()
                        }
                    }
                }
                .environment(viewModel)
            }
            .sheet(item: $selectedAgentForConfig) { (agent: CLIAgent) in
                AgentConfigSheet(viewModel: viewModel.agentSetupViewModel, agent: agent)
                    .id(sheetPresentationID)
                    .onDisappear {
                        viewModel.agentSetupViewModel.dismissConfiguration()
                        Task { await viewModel.agentSetupViewModel.refreshAgentStatuses() }
                    }
            }
            .fileImporter(
                isPresented: $isImporterPresented,
                allowedContentTypes: [.json],
                allowsMultipleSelection: false
            ) { result in
                if case .success(let urls) = result, let url = urls.first {
                    Task {
                        await viewModel.importVertexServiceAccount(url: url)
                        await viewModel.refreshData()
                    }
                }
            }
            .task {
                if modeManager.isLocalProxyMode {
                    await viewModel.agentSetupViewModel.refreshAgentStatuses()
                }
            }
        }
    }

    // MARK: - Full Mode Content

    private func fullModeContent(scrollProxy: ScrollViewProxy) -> some View {
        VStack(alignment: .leading, spacing: 20) {
            // 运行卡在停止和未安装时也保留，避免启动入口随状态切换而跳位。
            ProxyRuntimeCard()

            // 全局筛选固定紧接 CPA 运行卡；下面所有统计模块只消费同一份条件。
            CPADashboardCommonFilters(store: viewModel.usageMonitor, model: cpaDashboardModel,
                                      selection: $cpaSelection)

            if showGettingStarted {
                gettingStartedSection
            }

            DashboardUsageSummary(selection: $cpaSelection, dashboardModel: cpaDashboardModel)

        }
    }

    // MARK: - Quota-Only Mode Content

    private var quotaOnlyModeContent: some View {
        VStack(alignment: .leading, spacing: 24) {
            // Quota Overview KPIs
            quotaOnlyKPISection

            // Quick Quota Status
            quotaStatusSection

            // Tracked Accounts
            trackedAccountsSection
        }
    }

    private var quotaOnlyKPISection: some View {
        LazyVGrid(columns: [GridItem(.adaptive(minimum: 150), spacing: 12)], spacing: 12) {
            KPICard(
                title: "dashboard.trackedAccounts".localized(),
                value: "\(viewModel.monitorAccounts.count)",
                subtitle: "dashboard.accounts".localized(),
                icon: "person.2.fill",
                color: .blue
            )

            KPICard(
                title: "dashboard.providers".localized(),
                value: "\(directProvidersCount)",
                subtitle: "dashboard.connected".localized(),
                icon: "cpu",
                color: .green
            )

            // Show lowest quota percentage (precomputed)
            KPICard(
                title: "dashboard.lowestQuota".localized(),
                value: QuotaPercentagePresentation.text(lowestQuotaPercentage ?? -1),
                subtitle: "dashboard.remaining".localized(),
                icon: "chart.bar.fill",
                color: lowestQuotaColor
            )

            if let lastRefresh = viewModel.lastQuotaRefreshTime {
                KPICard(
                    title: "dashboard.lastRefresh".localized(),
                    value: lastRefresh.formatted(date: .omitted, time: .shortened),
                    subtitle: "dashboard.updated".localized(),
                    icon: "clock.fill",
                    color: .purple
                )
            }
        }
    }

    private var quotaStatusSection: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack {
                Label("dashboard.quotaOverview".localized(), systemImage: "chart.bar.fill")
                    .font(.headline)

                Spacer()

                if viewModel.isLoadingQuotas {
                    SmallProgressView()
                }
            }

            if viewModel.providerQuotas.isEmpty {
                VStack(spacing: 12) {
                    Image(systemName: "chart.bar.xaxis")
                        .font(.largeTitle)
                        .foregroundStyle(.tertiary)

                    Text("dashboard.noQuotaData".localized())
                        .font(.subheadline)
                        .foregroundStyle(.secondary)

                    Button {
                        Task { await viewModel.manualRefresh() }
                    } label: {
                        Label("action.refresh".localized(), systemImage: "arrow.clockwise")
                    }
                    .buttonStyle(.bordered)
                    .disabled(viewModel.isLoadingQuotas)
                }
                .frame(maxWidth: .infinity)
                .padding(.vertical, 20)
            } else {
                VStack(alignment: .leading, spacing: 12) {
                    // Sort providers for stable iteration order (ForEach performance fix)
                    ForEach(viewModel.providerQuotas.keys.sorted { $0.displayName < $1.displayName }) { provider in
                        if let accounts = viewModel.providerQuotas[provider], !accounts.isEmpty {
                            QuotaProviderRow(provider: provider, accounts: accounts)
                        }
                    }
                }
            }
        }
        .quotioCard()
    }

    private var trackedAccountsSection: some View {
        VStack(alignment: .leading, spacing: 14) {
            Label("dashboard.trackedAccounts".localized(), systemImage: "person.2.badge.key")
                .font(.headline)

            if viewModel.monitorAccounts.isEmpty {
                VStack(spacing: 12) {
                    Image(systemName: "person.crop.circle.badge.questionmark")
                        .font(.largeTitle)
                        .foregroundStyle(.tertiary)

                    Text("dashboard.noAccountsTracked".localized())
                        .font(.subheadline)
                        .foregroundStyle(.secondary)

                    Text("dashboard.addAccountsHint".localized())
                        .font(.caption)
                        .foregroundStyle(.tertiary)
                        .multilineTextAlignment(.center)
                }
                .frame(maxWidth: .infinity)
                .padding(.vertical, 20)
            } else {
                VStack(alignment: .leading, spacing: 8) {
                    ForEach(AIProvider.allCases.filter { groupedMonitorAccounts[$0] != nil }) { provider in
                        if let accounts = groupedMonitorAccounts[provider] {
                            HStack(spacing: 12) {
                                ProviderIcon(provider: provider, size: 20)

                                Text(provider.displayName)
                                    .font(.subheadline)
                                    .fontWeight(.medium)

                                Spacer()

                                Text("\(accounts.count)")
                                    .font(.caption)
                                    .padding(.horizontal, 8)
                                    .padding(.vertical, 2)
                                    .background(provider.color.opacity(0.15))
                                    .foregroundStyle(provider.color)
                                    .clipShape(Capsule())
                            }
                            .padding(.vertical, 4)
                        }
                    }
                }
            }
        }
        .quotioCard()
    }

    // MARK: - Getting Started Section

    private var gettingStartedSection: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack {
                Label("dashboard.gettingStarted".localized(), systemImage: "sparkles")
                    .font(.headline)

                Spacer()

                Button {
                    withAnimation { hideGettingStarted = true }
                } label: {
                    Image(systemName: "xmark")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
                .help("action.dismiss".localized())
            }

            VStack(alignment: .leading, spacing: 12) {
                ForEach(gettingStartedSteps) { step in
                    GettingStartedStepRow(
                        step: step,
                        onAction: { handleStepAction(step) }
                    )

                    if step.id != gettingStartedSteps.last?.id {
                        Divider()
                    }
                }
            }
        }
        .quotioCard()
    }

    private var gettingStartedSteps: [GettingStartedStep] {
        [
            GettingStartedStep(
                id: "provider",
                icon: "person.2.badge.key",
                title: "onboarding.addProvider".localized(),
                description: "onboarding.addProviderDesc".localized(),
                isCompleted: !viewModel.authFiles.isEmpty,
                actionLabel: viewModel.authFiles.isEmpty ? "providers.addProvider".localized() : nil
            ),
            GettingStartedStep(
                id: "agent",
                icon: "terminal",
                title: "onboarding.configureAgent".localized(),
                description: "onboarding.configureAgentDesc".localized(),
                isCompleted: viewModel.agentSetupViewModel.agentStatuses.contains(where: { $0.configured }),
                actionLabel: viewModel.agentSetupViewModel.agentStatuses.contains(where: { $0.configured }) ? nil : "agents.configure".localized()
            )
        ]
    }

    private func handleStepAction(_ step: GettingStartedStep) {
        switch step.id {
        case "provider":
            showProviderPicker()
        case "agent":
            showAgentPicker()
        default:
            break
        }
    }

    private func showProviderPicker() {
        let alert = NSAlert()
        alert.messageText = "providers.addProvider".localized()
        alert.informativeText = "onboarding.addProviderDesc".localized()

        let providers = AIProvider.allCases.filter(\.supportsLocalProxySetup)
        for provider in providers {
            alert.addButton(withTitle: provider.displayName)
        }
        alert.addButton(withTitle: "action.cancel".localized())

        let response = alert.runModal()
        let index = response.rawValue - 1000

        if index >= 0 && index < providers.count {
            let provider = providers[index]
            if provider == .vertex {
                isImporterPresented = true
            } else {
                viewModel.oauthState = nil
                selectedProvider = provider
            }
        }
    }

    private func showAgentPicker() {
        let installedAgents = viewModel.agentSetupViewModel.agentStatuses.filter { $0.installed }
        guard let firstAgent = installedAgents.first else { return }

        let apiKey = viewModel.apiKeys.first ?? viewModel.proxyManager.managementKey
        viewModel.agentSetupViewModel.startConfiguration(for: firstAgent.agent, apiKey: apiKey)
        sheetPresentationID = UUID()
        selectedAgentForConfig = firstAgent.agent
    }


}

/// 手动操作与后台轮询解耦，避免导航按钮每轮采集都在可用和禁用外观间闪动。
/// 模式及代理状态只在点击时读取；刷新中的局部状态不会使整个仪表盘重新求值。
private struct DashboardRefreshButton: View {
    @Environment(QuotaViewModel.self) private var viewModel
    @State private var isRefreshing = false

    var body: some View {
        Button {
            guard !isRefreshing else { return }
            isRefreshing = true
            Task {
                defer { isRefreshing = false }
                let modeManager = OperatingModeManager.shared
                if modeManager.isMonitorMode {
                    await viewModel.manualRefresh()
                } else if modeManager.isLocalProxyMode && viewModel.proxyManager.proxyStatus.running {
                    await viewModel.refreshDashboard()
                } else {
                    await viewModel.refreshQuotasUnified()
                }
            }
        } label: {
            Image(systemName: "arrow.clockwise")
        }
        .disabled(isRefreshing || viewModel.isRefreshingDashboard)
        .help("action.refresh".localized())
        .accessibilityLabel("action.refresh".localized())
    }
}

// MARK: - Getting Started Step

struct GettingStartedStep: Identifiable {
    let id: String
    let icon: String
    let title: String
    let description: String
    let isCompleted: Bool
    let actionLabel: String?
}

struct GettingStartedStepRow: View {
    let step: GettingStartedStep
    let onAction: () -> Void

    var body: some View {
        HStack(spacing: 16) {
            ZStack {
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .fill(step.isCompleted ? Color.green : Color.accentColor.opacity(0.15))
                    .frame(width: 40, height: 40)

                if step.isCompleted {
                    Image(systemName: "checkmark")
                        .font(.system(size: 16, weight: .bold))
                        .foregroundStyle(.white)
                } else {
                    Image(systemName: step.icon)
                        .font(.system(size: 16))
                        .foregroundStyle(Color.accentColor)
                }
            }

            VStack(alignment: .leading, spacing: 4) {
                HStack {
                    Text(step.title)
                        .font(.headline)

                    if step.isCompleted {
                        Image(systemName: "checkmark.circle.fill")
                            .foregroundStyle(.green)
                            .font(.caption)
                    }
                }

                Text(step.description)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }

            Spacer()

            if let actionLabel = step.actionLabel {
                Button(actionLabel) {
                    onAction()
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.small)
            }
        }
        .padding(.vertical, 8)
    }
}

// MARK: - KPI Card

struct KPICard: View {
    @Environment(\.colorScheme) private var colorScheme
    let title: String
    let value: String
    let subtitle: String
    let icon: String
    let color: Color

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: icon)
                .font(.system(size: 15, weight: .semibold))
                .foregroundStyle(color)
                .frame(width: 32, height: 32)
                .background(color.opacity(0.12), in: RoundedRectangle(cornerRadius: 8, style: .continuous))

            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(.caption2.weight(.medium))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .minimumScaleFactor(0.85)

                Text(value)
                    .font(.system(size: 18, weight: .bold, design: .rounded))
                    .foregroundStyle(color)
                    .monospacedDigit()
                    .lineLimit(1)

                if !subtitle.isEmpty && subtitle != "—" {
                    Text(subtitle)
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .minimumScaleFactor(0.85)
                }
            }

            Spacer(minLength: 0)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .quotioCard(cornerRadius: QuotioTheme.Radius.md, padding: 12)
        .accessibilityElement(children: .combine)
    }
}

// MARK: - Provider Chip

struct ProviderChip: View {
    let provider: AIProvider
    let count: Int

    var body: some View {
        HStack(spacing: 6) {
            ProviderIcon(provider: provider, size: 16)
            Text(provider.displayName)
            if count > 1 {
                Text("×\(count)")
                    .font(.caption.monospacedDigit())
                    .fontWeight(.semibold)
            }
        }
        .font(.caption)
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
        .background(provider.color.opacity(0.15))
        .foregroundStyle(provider.color)
        .clipShape(Capsule())
    }
}

// MARK: - Flow Layout

struct FlowLayout: Layout {
    var spacing: CGFloat = 8

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let result = layout(proposal: proposal, subviews: subviews)
        return result.size
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        let result = layout(proposal: proposal, subviews: subviews)
        for (index, subview) in subviews.enumerated() {
            subview.place(at: CGPoint(x: bounds.minX + result.positions[index].x, y: bounds.minY + result.positions[index].y), proposal: .unspecified)
        }
    }

    private func layout(proposal: ProposedViewSize, subviews: Subviews) -> (size: CGSize, positions: [CGPoint]) {
        var positions: [CGPoint] = []
        var currentX: CGFloat = 0
        var currentY: CGFloat = 0
        var lineHeight: CGFloat = 0
        let maxWidth = proposal.width ?? .infinity

        for subview in subviews {
            let size = subview.sizeThatFits(.unspecified)

            if currentX + size.width > maxWidth && currentX > 0 {
                currentX = 0
                currentY += lineHeight + spacing
                lineHeight = 0
            }

            positions.append(CGPoint(x: currentX, y: currentY))
            currentX += size.width + spacing
            lineHeight = max(lineHeight, size.height)
        }

        return (CGSize(width: maxWidth, height: currentY + lineHeight), positions)
    }
}

// MARK: - Quota Provider Row (for Quota-Only Mode Dashboard)

struct QuotaProviderRow: View {
    let provider: AIProvider
    let accounts: [String: ProviderQuotaData]

    private var lowestQuota: Double? {
        // 余额、状态行与未知百分比均不参与汇总，纯余额账号显示占位而不是 -1%。
        QuotaPercentagePresentation.lowestRemaining(in: accounts.values.flatMap(\.models))
    }

    private var quotaColor: Color {
        guard let lowestQuota else { return .secondary }
        if lowestQuota > 50 { return .green }
        if lowestQuota > 20 { return .orange }
        return .red
    }

    var body: some View {
        HStack(spacing: 12) {
            ProviderIcon(provider: provider, size: 24)

            VStack(alignment: .leading, spacing: 2) {
                Text(provider.displayName)
                    .font(.subheadline)
                    .fontWeight(.medium)

                Text("\(accounts.count) " + "quota.accounts".localized())
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Spacer()

            // Lowest quota indicator
            HStack(spacing: 6) {
                Circle()
                    .fill(quotaColor)
                    .frame(width: 8, height: 8)

                Text(QuotaPercentagePresentation.text(lowestQuota ?? -1))
                    .font(.subheadline)
                    .fontWeight(.semibold)
                    .foregroundStyle(quotaColor)
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 4)
            .background(quotaColor.opacity(0.1))
            .clipShape(Capsule())
        }
        .padding(.vertical, 6)
    }
}
