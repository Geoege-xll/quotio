import SwiftUI

/// 保留舞台、最近执行解释、执行列表三张卡片，由这一层统一读取数据与配置。
/// 子组件只消费环境中的展示模型，不能各自触发 CPA 队列消费或重复 SQL 聚合。
struct RoutingCenterView: View {
    @Environment(QuotaViewModel.self) private var viewModel
    @Environment(\.scenePhase) private var scenePhase
    @State private var routing = CPARoutingViewModel()

    private var store: UsageStatisticsStore { viewModel.usageMonitor }
    private var activeClient: ManagementAPIClient? {
        // 运行状态先失效配置，即使客户端销毁尚在异步处理中，也不能显示上轮策略。
        viewModel.proxyManager.proxyStatus.running ? viewModel.apiClient : nil
    }
    private var clientID: ObjectIdentifier? { activeClient.map { ObjectIdentifier($0) } }

    var body: some View {
        RoutingCenterCards()
        .environment(routing)
        // task(id:) 自动取消旧修订的读取，模型再检查查询代次，防止较慢结果倒灌。
        .task(id: store.statisticsRevision) { await reload() }
        .task(id: clientID) { await routing.reloadConfiguration(client: activeClient) }
        .task {
            // 空队列心跳不会改变修订号；独立检查自然日，确保午夜无新请求也能失效。
            // 该循环只在跨日时查库，常规时刻不增加 SQL 扫描或队列消费。
            while !Task.isCancelled {
                do { try await Task.sleep(for: .seconds(30)) } catch { return }
                if routing.snapshot.start != Calendar.current.startOfDay(for: .now) { await reload() }
            }
        }
        .onChange(of: scenePhase) { _, phase in
            guard phase == .active else { return }
            Task {
                await reload()
                await routing.reloadConfiguration(client: activeClient)
            }
        }
    }

    private func reload() async {
        await routing.reload { now in try await store.queryRoutingSnapshot(now: now) }
    }
}

/// 纯展示卡片组与父层查询生命周期分开：生产和原生布局验证使用同一间距、
/// 异常提示及三个组件；测试可以注入离线快照，不执行队列消费或读取真实账本。
struct RoutingCenterCards: View {
    @Environment(CPARoutingViewModel.self) private var routing
    let settings: MenuBarSettingsManager

    init(settings: MenuBarSettingsManager = .shared) { self.settings = settings }

    var body: some View {
        // 保持卡片顺序，仅把原有 20pt 卡片间距收紧为 12pt。
        VStack(alignment: .leading, spacing: 12) {
            if routing.hasReadError {
                Label("routing.data.readError".localized(), systemImage: "exclamationmark.triangle")
                    .font(.caption)
                    .foregroundStyle(.orange)
            }
            RoutingStageView(settings: settings)
            RoutingLastRequestTraceView(settings: settings)
            RoutingLiveRequestsView(settings: settings)
        }
    }
}
