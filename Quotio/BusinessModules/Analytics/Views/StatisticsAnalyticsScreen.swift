import SwiftUI

/// 统一统计入口。两个 Tab 的视图始终保留在同一个稳定的 ZStack 中，
/// 隐藏时关闭交互及辅助功能访问，从而保留原生 ScrollView 的偏移、展开状态和筛选。
/// 可见性单独传给查询／扫描生命周期，隐藏页面不会因保留视图而继续读取日志或轮询 SQL。
struct StatisticsAnalyticsScreen: View {
    let clientUsage: ClientUsageViewModel
    let callAnalytics: CallAnalyticsViewModel
    /// 只注入页面实际读取的 CPA 服务和账号数量，避免订阅整个配额模型；
    /// 同时允许原生窗口回归使用临时账本，不触碰真实代理或用户会话。
    let store: UsageStatisticsStore
    let totalAccounts: Int
    let readyAccounts: Int
    @Environment(AnalyticsNavigationState.self) private var navigation
    @State private var path = NavigationPath()

    var body: some View {
        @Bindable var state = navigation
        NavigationStack(path: $path) {
            ZStack {
                CPAUsageAnalysisScreen(store: store, selection: $state.cpaSelection,
                    dashboardModel: state.cpaDashboardModel,
                    totalAccounts: totalAccounts, readyAccounts: readyAccounts,
                    isActive: state.tab == .usage && path.isEmpty)
                    .opacity(state.tab == .usage ? 1 : 0)
                    .allowsHitTesting(state.tab == .usage)
                    // 隐藏页也禁用键盘控件，防止 Tab 键把焦点移到透明的筛选或明细按钮。
                    .disabled(state.tab != .usage)
                    .accessibilityHidden(state.tab != .usage)

                CallAnalyticsScreen(viewModel: callAnalytics, clientUsage: clientUsage, isActive: state.tab == .calls && path.isEmpty)
                    .opacity(state.tab == .calls ? 1 : 0)
                    .allowsHitTesting(state.tab == .calls)
                    .disabled(state.tab != .calls)
                    .accessibilityHidden(state.tab != .calls)
            }
            .navigationTitle("nav.analytics".localized())
            .toolbar {
                ToolbarItem(placement: .principal) {
                    topSegmentedControl(tab: $state.tab)
                }
                if state.tab == .usage {
                    ToolbarItem(placement: .primaryAction) {
                        NavigationLink(value: CPAUsageDestination.records(state.cpaSelection)) {
                            Label("usage.dashboard.records".localized(), systemImage: "list.bullet.rectangle")
                        }
                    }
                    ToolbarItem(placement: .primaryAction) {
                        NavigationLink(value: CPAUsageDestination.pricing(state.cpaSelection)) {
                            Label("usage.pricing.title".localized(), systemImage: "dollarsign.circle")
                        }
                    }
                    ToolbarItem(placement: .primaryAction) {
                        ManualRefreshButton(helpKey: "usage.refresh") {
                            await store.refreshForUser()
                            // 等当前采集批次落盘后立即重读报表；无新用量也可更新滚动时间窗。
                            // 手动重读仅改变查询代次，不清空图表、筛选或原生滚动容器。
                            state.cpaDashboardModel.requestRefresh()
                        }
                    }
                }
            }
            .navigationDestination(for: CPAUsageDestination.self) { destination in
                switch destination {
                case .records(let selection):
                    CPAUsageRecordsView(store: store, selection: selection)
                case .pricing(let selection):
                    CPAUsagePricingView(store: store, selection: selection)
                }
            }
        }
    }

    private func topSegmentedControl(tab: Binding<AnalyticsTab>) -> some View {
        QuotioCapsuleSegmentedControl(
            options: AnalyticsTab.allCases,
            selection: tab,
            size: .small,
            isEqualWidth: false
        ) { option, isSelected in
            HStack(spacing: 5) {
                Image(systemName: option.icon)
                    .font(.system(size: 10.5, weight: isSelected ? .semibold : .medium))
                Text(option.title)
                    .font(.system(size: 11.5, weight: isSelected ? .semibold : .medium))
            }
        }
        .fixedSize()
        .accessibilityIdentifier("analyticsTabPicker")
    }
}

/// 完整 CPA 分析复用现有筛选、汇总及索引查询，页面不直接请求消费式 usage-queue。
/// 根滚动视图保留原生偏移；筛选条、趋势及排行都读取同一份由宿主持有的条件。
private struct CPAUsageAnalysisScreen: View {
    let store: UsageStatisticsStore
    @Binding var selection: CPAUsageSelection
    let dashboardModel: CPAUsageDashboardViewModel
    let totalAccounts: Int
    let readyAccounts: Int
    let isActive: Bool
    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                CPADashboardCommonFilters(store: store, model: dashboardModel, selection: $selection)
                CPAUsageStatisticsView(store: store, totalAccounts: totalAccounts, readyAccounts: readyAccounts,
                    selection: $selection, dashboardModel: dashboardModel, isActive: isActive)
            }
            .padding(20)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .analyticsPageChrome(colorScheme)
        .accessibilityIdentifier("analyticsCPAUsagePage")
    }
}

