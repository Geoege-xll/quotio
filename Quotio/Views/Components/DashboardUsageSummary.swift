import SwiftUI

/// 仪表盘组合层只注入共享采集服务和账号概况，CPA 统计布局不依赖整个 QuotaViewModel。
/// 本地用量页不复用此组件，也不把本地日志与 CPA 请求合并。
struct DashboardUsageSummary: View {
    @Environment(QuotaViewModel.self) private var viewModel
    @Binding var selection: CPAUsageSelection
    let dashboardModel: CPAUsageDashboardViewModel

    var body: some View {
        CPAUsageStatisticsView(store: viewModel.usageMonitor,
                               totalAccounts: viewModel.totalAccounts,
                               readyAccounts: viewModel.readyAccounts,
                               selection: $selection,
                               dashboardModel: dashboardModel)
    }
}
