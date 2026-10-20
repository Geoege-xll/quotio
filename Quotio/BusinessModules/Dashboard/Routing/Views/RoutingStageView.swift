// 路由拓扑展示：历史节点来自 CPA 上游执行，待命节点来自真实客户端与账号目录。
// 成功／失败／取消保持执行终态；最近活动只作短时强调，不代表入站请求尚在执行。
// 缺失账号或客户端身份保留未知，动画只由刚采集到的执行事件触发。

import SwiftUI
import AppKit

// MARK: - Dynamic Node Models

private struct DynamicAgentNode: Identifiable, Equatable {
    let id: String
    let name: String
    let modelName: String
    let icon: String
    let tint: Color
    let isActive: Bool
}

private struct DynamicTargetNode: Identifiable, Equatable {
    let id: String
    let providerName: String
    let accountName: String
    let statusText: String
    let status: TargetStatus
    let isActive: Bool

    enum TargetStatus: Equatable {
        case standby
        case success
        case canceled
        case failure
    }
}

// MARK: - Main Routing Stage View

struct RoutingStageView: View {
    @Environment(QuotaViewModel.self) private var viewModel
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.scenePhase) private var scenePhase
    @Environment(CPARoutingViewModel.self) private var routing
    @State private var settings: MenuBarSettingsManager

    /// 测试注入独立偏好，生产页面沿用全局隐私设置；渲染本身不写账号或配置。
    init(settings: MenuBarSettingsManager = .shared) { _settings = State(initialValue: settings) }

    // 节点直接由共享快照和当前目录派生，账号／客户端配置变化会立即更新待命态。
    // 不把父层输入复制成 @State，避免显示旧邮箱、已禁用账号或过期客户端。
    @State private var now = Date()
    private var hasRoutedRequests: Bool { !routing.snapshot.events.isEmpty }

    /// 节点强调使用采集到达时钟，最多持续 12 秒；逐帧光流由独立连线层负责。
    /// 活动结束或场景不可见后停止此低频时钟，不持续使整张卡片重新求值。
    private struct ActivityClockKey: Hashable {
        let lastArrival: Date?
        let enabled: Bool
    }
    private var activityClockKey: ActivityClockKey {
        ActivityClockKey(lastArrival: routing.activities.map(\.receivedAt).max(),
                         enabled: isCollecting && scenePhase == .active)
    }

    private var proxyManager: CLIProxyManager { viewModel.proxyManager }
    private var isRunning: Bool { proxyManager.proxyStatus.running }
    private var store: UsageStatisticsStore { viewModel.usageMonitor }

    private var availableAccountsCount: Int {
        viewModel.authFiles.filter { !$0.disabled && !$0.unavailable }.count
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            stageHeader

            // 核心拓扑连接舞台
            topologyStage
                .frame(minHeight: 136)

        }
        .quotioCard()
        .help("routing.data.scopeHelp".localized())
        .task(id: activityClockKey) {
            now = .now
            guard activityClockKey.enabled else { return }
            // 这里只更新节点强调时间，不查询数据库，也不改变执行终态。
            while routing.activities.contains(where: { $0.isRecent(at: now) }) {
                do { try await Task.sleep(for: .seconds(1)) } catch { return }
                now = .now
            }
        }
    }

    // MARK: - Header Bar

    private var stageHeader: some View {
        HStack(alignment: .center, spacing: 8) {
            Label("routing.stage.title".localized(), systemImage: "arrow.triangle.branch")
                .font(.headline)
                .foregroundStyle(.primary)

            Spacer()

            if isRunning {
                kpiPill(
                    title: "routing.kpi.retry".localized(),
                    value: routing.retryRounds.map { String(format: "routing.kpi.roundsValue".localized(), $0) } ?? "—",
                    tint: .orange
                )

                HStack(spacing: 6) {
                    Circle()
                        .fill(isCollecting ? Color.green : Color.orange)
                        .frame(width: 7, height: 7)
                        .shadow(color: Color.green.opacity(0.6), radius: 3)

                    // 正常状态不再单独占一行；读取异常仍必须明确显示文字，
                    // 不能仅把圆点改成橙色，却继续声称“实时采集”。父层详细警告保留。
                    Text((routing.hasReadError ? "routing.data.readError" : store.statusKey).localized())
                        .font(.system(size: 11, weight: .medium))
                        .foregroundStyle(.secondary)
                }
                .padding(.horizontal, 9)
                .padding(.vertical, 3)
                .background(QuotioTheme.Colors.cardInset(for: colorScheme), in: Capsule())
            } else {
                HStack(spacing: 5) {
                    Circle()
                        .fill(Color.secondary.opacity(0.6))
                        .frame(width: 6, height: 6)

                    Text("runtime.stopped".localized())
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                }
                .padding(.horizontal, 8)
                .padding(.vertical, 2.5)
                .background(QuotioTheme.Colors.cardInset(for: colorScheme), in: Capsule())
            }
        }
    }

    // MARK: - Interactive Topology Stage

    private var topologyStage: some View {
        GeometryReader { proxy in
            let w = proxy.size.width
            let h = proxy.size.height

            let hubWidth: CGFloat = 138
            // 节点卡片收窄：最大 148pt，确保不被宽屏拉伸得太空，同时窄屏自适应
            let colWidth: CGFloat = min(148, max(115, (w - hubWidth - 48) / 2))
            HStack(alignment: .center, spacing: 0) {
                agentsColumn
                    .frame(width: colWidth)
                Spacer(minLength: 12)
                routerGatewayHub
                    .frame(width: hubWidth)
                Spacer(minLength: 12)
                targetsColumn
                    .frame(width: colWidth)
            }
            .frame(width: w, height: h)
            .backgroundPreferenceValue(RoutingNodeAnchorPreference.self) { anchors in
                GeometryReader { canvas in
                    // 在同一坐标空间解析真实节点边界。连线在节点背景后方，光流不会
                    // 遮挡文字、抢占点击或影响既有四项指标及其他卡片的布局。
                    let bounds = anchors.mapValues { canvas[$0] }
                    RoutingFlowConnections(geometry: RoutingFlowGeometry(anchors: bounds),
                                           activities: routing.activities,
                                           isEnabled: isCollecting && scenePhase == .active)
                }
            }
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 8)
        .background(
            QuotioTheme.Colors.cardInset(for: colorScheme).opacity(0.45),
            in: RoundedRectangle(cornerRadius: 12, style: .continuous)
        )
    }

    // MARK: - Column 1: Dynamic Agents (展示真实客户端，绝不伪造)

    private var agentsColumn: some View {
        VStack(alignment: .leading, spacing: 6) {
            // 列小标题
            HStack(spacing: 5) {
                Image(systemName: "desktopcomputer")
                    .font(.system(size: 10, weight: .medium))
                    .foregroundStyle(.secondary)
                Text("routing.sources.title".localized())
                    .font(.system(size: 10.5, weight: .semibold))
                    .foregroundStyle(.secondary)
                Spacer()
                Text("\(activeAgents.count)")
                    .font(.system(size: 9.5, weight: .bold))
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 5)
                    .padding(.vertical, 1)
                    .background(QuotioTheme.Colors.cardInset(for: colorScheme), in: Capsule())
            }
            .padding(.horizontal, 2)

            // 客户端列表 (完全源于真实历史或真实已安装配置项)
            VStack(spacing: 5) {
                if activeAgents.isEmpty {
                    emptyAgentsPlaceholder
                } else {
                    ForEach(activeAgents) { agent in
                        agentItemRow(agent: agent)
                            .anchorPreference(key: RoutingNodeAnchorPreference.self, value: .bounds) {
                                [.source(agent.id): $0]
                            }
                    }
                }
            }
        }
    }

    private var emptyAgentsPlaceholder: some View {
        VStack(spacing: 4) {
            Image(systemName: "terminal")
                .font(.system(size: 16))
                .foregroundStyle(.tertiary)
            Text("routing.empty.waitingAgent".localized())
                .font(.system(size: 10))
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, minHeight: 70)
        .background(
            QuotioTheme.Colors.cardInset(for: colorScheme).opacity(0.3),
            in: RoundedRectangle(cornerRadius: 8, style: .continuous)
        )
    }

    private func agentItemRow(agent: DynamicAgentNode) -> some View {
        HStack(spacing: 7) {
            ZStack {
                RoundedRectangle(cornerRadius: 6, style: .continuous)
                    .fill(agent.tint.opacity(agent.isActive ? 0.22 : 0.12))
                    .frame(width: 22, height: 22)

                Image(systemName: agent.icon)
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(agent.tint)
            }

            VStack(alignment: .leading, spacing: 1) {
                Text(agent.name)
                    .font(.system(size: 11, weight: agent.isActive ? .semibold : .medium))
                    .foregroundStyle(agent.isActive ? .primary : .secondary)
                    .lineLimit(1)

                if !agent.modelName.isEmpty {
                    Text(agent.modelName)
                        .font(.system(size: 9, design: .monospaced))
                        .foregroundStyle(.tertiary)
                        .lineLimit(1)
                }
            }

            Spacer(minLength: 2)

            // 状态指示 (最近活跃只保留绿点)
            if agent.isActive {
                Circle()
                    .fill(Color.green)
                    .frame(width: 5.5, height: 5.5)
                    .shadow(color: Color.green.opacity(0.6), radius: 2.5)
            } else {
                Circle()
                    .fill(Color.secondary.opacity(0.3))
                    .frame(width: 4.5, height: 4.5)
            }
        }
        .padding(.horizontal, 7)
        .padding(.vertical, 4.5)
        .background(
            QuotioTheme.Colors.cardElevated(for: colorScheme).opacity(agent.isActive ? 1.0 : 0.65),
            in: RoundedRectangle(cornerRadius: 8, style: .continuous)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .strokeBorder(
                    agent.isActive ? agent.tint.opacity(0.55) : Color.primary.opacity(0.04),
                    lineWidth: 1
                )
        )
    }

    // MARK: - Center: Router Gateway Hub (网关中枢控制器卡片包裹)

    private var routerGatewayHub: some View {
        VStack(spacing: 5) {
            ZStack {
                // 调度底座
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .fill(
                        LinearGradient(
                            colors: [
                                Color.accentColor.opacity(isRunning ? 0.95 : 0.5),
                                (Color(hex: "7C3AED") ?? .purple).opacity(isRunning ? 1.0 : 0.5)
                            ],
                            startPoint: .topLeading,
                            endPoint: .bottomTrailing
                        )
                    )
                    .frame(width: 32, height: 32)
                    .shadow(color: Color.accentColor.opacity(isRunning ? 0.35 : 0.05), radius: 5, x: 0, y: 2)

                Image(systemName: "arrow.triangle.branch")
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundStyle(.white)
            }

            VStack(spacing: 1) {
                Text("Quotio Router")
                    .font(.system(size: 11, weight: .bold))
                    .foregroundStyle(.primary)

                if isRunning {
                    Text(":\(proxyManager.port)")
                        .font(.system(size: 9, weight: .semibold, design: .monospaced))
                        .foregroundStyle(.secondary)
                } else {
                    Text("runtime.stopped".localized())
                        .font(.system(size: 9))
                        .foregroundStyle(.secondary)
                }
            }

            // 调度策略与故障切换微胶囊
            HStack(spacing: 4) {
                Text(routing.routingStrategy.map { CPARoutingStrategy.displayName(for: $0) } ?? "—")
                    .font(.system(size: 9, weight: .semibold))
                    .foregroundStyle(isRunning ? Color.accentColor : Color.secondary)
                    .padding(.horizontal, 6)
                    .padding(.vertical, 1.5)
                    .background((isRunning ? Color.accentColor : Color.secondary).opacity(0.12), in: Capsule())

                if isRunning {
                    HStack(spacing: 2.5) {
                        Image(systemName: "shield.checkmark.fill")
                            .font(.system(size: 7))
                        Text("routing.kpi.failover".localized())
                            .font(.system(size: 9, weight: .semibold))
                    }
                    .foregroundStyle(Color.purple)
                    .padding(.horizontal, 6)
                    .padding(.vertical, 1.5)
                    .background(Color.purple.opacity(0.12), in: Capsule())
                    .help("routing.failover.active".localized())
                }
            }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 7)
        .background(
            QuotioTheme.Colors.cardElevated(for: colorScheme),
            in: RoundedRectangle(cornerRadius: 12, style: .continuous)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .strokeBorder(
                    Color.accentColor.opacity(isRunning ? 0.25 : 0.08),
                    lineWidth: 1
                )
        )
        // 中枢卡片整体作为连接锚点，曲线从卡片外边缘平滑接入与接出
        .anchorPreference(key: RoutingNodeAnchorPreference.self, value: .bounds) { [.hub: $0] }
    }

    // MARK: - Column 2: Dynamic Targets (展示真实账号，绝不伪造)

    private var targetsColumn: some View {
        VStack(alignment: .leading, spacing: 6) {
            // 列小标题
            HStack(spacing: 5) {
                Image(systemName: "server.rack")
                    .font(.system(size: 10, weight: .medium))
                    .foregroundStyle(.secondary)
                Text("routing.targets.title".localized())
                    .font(.system(size: 10.5, weight: .semibold))
                    .foregroundStyle(.secondary)
                Spacer()
                Text("\(availableAccountsCount)")
                    .font(.system(size: 9.5, weight: .bold))
                    .foregroundStyle(Color.green)
                    .padding(.horizontal, 5.5)
                    .padding(.vertical, 1)
                    .background(Color.green.opacity(0.12), in: Capsule())
            }
            .padding(.horizontal, 2)

            // 上游账号列表 (完全源于用户真实添加的 AuthFiles 或真实调用的账号)
            VStack(spacing: 5) {
                if activeTargets.isEmpty {
                    emptyTargetsPlaceholder
                } else {
                    ForEach(activeTargets) { target in
                        targetItemRow(target: target)
                            .anchorPreference(key: RoutingNodeAnchorPreference.self, value: .bounds) {
                                [.target(target.id): $0]
                            }
                    }
                }
            }
        }
    }

    private var emptyTargetsPlaceholder: some View {
        VStack(spacing: 4) {
            Image(systemName: "person.crop.circle.badge.plus")
                .font(.system(size: 16))
                .foregroundStyle(.tertiary)
            Text("routing.targets.empty".localized())
                .font(.system(size: 10))
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity, minHeight: 70)
        .background(
            QuotioTheme.Colors.cardInset(for: colorScheme).opacity(0.3),
            in: RoundedRectangle(cornerRadius: 8, style: .continuous)
        )
    }

    private func targetItemRow(target: DynamicTargetNode) -> some View {
        HStack(spacing: 7) {
            // 状态指示点
            Circle()
                .fill(statusColor(for: target.status).opacity(target.isActive ? 1.0 : (target.status == .standby ? 0.35 : 0.6)))
                .frame(width: 5, height: 5)
                .shadow(color: (target.isActive ? statusColor(for: target.status) : Color.clear).opacity(0.6), radius: 2.5)

            VStack(alignment: .leading, spacing: 1) {
                Text(target.providerName)
                    .font(.system(size: 11, weight: target.isActive ? .semibold : .medium))
                    .foregroundStyle(target.isActive ? .primary : .secondary)
                    .lineLimit(1)

                if !target.accountName.isEmpty {
                    Text(target.accountName)
                        .font(.system(size: 9, design: .monospaced))
                        .foregroundStyle(.tertiary)
                        .lineLimit(1)
                }
            }

            Spacer(minLength: 2)

            // 状态标签：只有真正成功或异常时才显示状态胶囊，待命状态不显示假成功
            if target.status == .success {
                Text(target.statusText)
                    .font(.system(size: 9, weight: .medium))
                    .foregroundStyle(Color.green)
                    .padding(.horizontal, 5)
                    .padding(.vertical, 1.5)
                    .background(Color.green.opacity(0.12), in: Capsule())
            } else if target.status == .failure {
                Text(target.statusText)
                    .font(.system(size: 9, weight: .medium))
                    .foregroundStyle(Color.red)
                    .padding(.horizontal, 5)
                    .padding(.vertical, 1.5)
                    .background(Color.red.opacity(0.12), in: Capsule())
            } else if target.status == .canceled {
                Text(target.statusText)
                    .font(.system(size: 9, weight: .medium))
                    .foregroundStyle(Color.orange)
                    .padding(.horizontal, 5)
                    .padding(.vertical, 1.5)
                    .background(Color.orange.opacity(0.12), in: Capsule())
            }
        }
        .padding(.horizontal, 7)
        .padding(.vertical, 4.5)
        .background(
            QuotioTheme.Colors.cardElevated(for: colorScheme).opacity(target.isActive ? 1.0 : 0.65),
            in: RoundedRectangle(cornerRadius: 8, style: .continuous)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .strokeBorder(
                    target.isActive ? Color.accentColor.opacity(0.55) : Color.primary.opacity(0.04),
                    lineWidth: 1
                )
        )
    }

    private func statusColor(for status: DynamicTargetNode.TargetStatus) -> Color {
        switch status {
        case .standby: return Color.secondary
        case .success: return Color.green
        case .canceled: return Color.orange
        case .failure: return Color.red
        }
    }

    // MARK: - Resilience KPI Pill

    private func kpiPill(title: String, value: String, tint: Color) -> some View {
        HStack(spacing: 0) {
            Text(title + ": ").foregroundStyle(.secondary)
            Text(value).foregroundStyle(tint).fontWeight(.semibold)
        }
            .font(.system(size: 11))
            .lineLimit(1)
            .padding(.horizontal, 7)
            .padding(.vertical, 3)
            .background(QuotioTheme.Colors.cardInset(for: colorScheme), in: Capsule())
            .help(title + ": " + value)
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(title + ": " + value)
    }

    // MARK: - Arrival Activity & Dynamic Nodes

    private var isCollecting: Bool { isRunning && store.state == .live && !routing.hasReadError }

    /// “最近活动”表示刚采集到执行，不表示请求仍在运行；慢请求沿用终态标签。
    private func sourceIsActive(_ id: String) -> Bool {
        isCollecting && routing.activities.contains { $0.sourceID == id && $0.isRecent(at: now) }
    }
    private func targetIsActive(_ id: String) -> Bool {
        isCollecting && routing.activities.contains { $0.targetID == id && $0.isRecent(at: now) }
    }

    private var activeAgents: [DynamicAgentNode] {
        guard hasRoutedRequests else {
            return viewModel.agentSetupViewModel.agentStatuses.filter { $0.configured || $0.installed }
                .prefix(3).map { status in
                    DynamicAgentNode(id: status.agent.rawValue, name: status.agent.displayName,
                        modelName: "routing.empty.standby".localized(), icon: status.agent.systemIcon,
                        tint: status.agent.color, isActive: false)
                }
        }
        var seen = Set<String>()
        return routing.stageEvents.compactMap { event -> DynamicAgentNode? in
            let id = CPARoutingPresentation.sourceID(for: event)
            guard seen.insert(id).inserted else { return nil }
            let client = event.context.client ?? ""
            return DynamicAgentNode(id: id,
                name: CPARoutingPresentation.sourceName(for: event, hidden: settings.hideSensitiveInfo),
                modelName: event.context.alias ?? event.model, icon: agentIcon(for: client),
                tint: agentColor(for: client), isActive: sourceIsActive(id))
        }.prefix(3).map { $0 }
    }

    private var activeTargets: [DynamicTargetNode] {
        guard hasRoutedRequests else {
            return viewModel.authFiles.filter { !$0.disabled && !$0.unavailable }.prefix(3).map { auth in
                DynamicTargetNode(id: auth.id, providerName: ProviderDisplayName.normalize(auth.provider),
                    accountName: auth.quotaDisplayName.masked(if: settings.hideSensitiveInfo),
                    statusText: "", status: .standby, isActive: false)
            }.sorted { $0.id < $1.id }
        }
        var seen = Set<String>()
        return routing.stageEvents.compactMap { event -> DynamicTargetNode? in
            let id = CPARoutingPresentation.targetID(for: event)
            guard seen.insert(id).inserted else { return nil }
            let status: DynamicTargetNode.TargetStatus = event.outcome == .success ? .success
                : (event.outcome == .canceled ? .canceled : .failure)
            // CPA 事件只带协议家族；跨协议接入的第三方模型按模型 ID 识别真实品牌。
            return DynamicTargetNode(id: id,
                providerName: ProviderDisplayName.eventProviderName(provider: event.provider, model: event.model),
                accountName: CPARoutingPresentation.accountName(for: event, files: viewModel.authFiles,
                    hidden: settings.hideSensitiveInfo),
                statusText: CPARoutingPresentation.outcomeKey(event.outcome).localized(), status: status,
                isActive: targetIsActive(id))
        }
        // 最近活动仅决定哪些真实账号进入最多三个可见节点、以及各账号的最新状态。
        // 入选后按不可变账号身份固定排列，不按活动时间、成功状态或脱敏显示名称排序。
        // 否则 A→B→A 轮询会把目标账号每次搬到第一行，光流虽匹配了正确 targetID，
        // 却总落在同一条物理曲线。这里不缓存账号对象或坐标，真实锚点仍随布局测量，
        // 因而保留已有慢请求优先入场、账号信息更新、隐私隐藏和窗口缩放行为。
        .prefix(3).sorted { $0.id < $1.id }
    }

    private func agentIcon(for label: String) -> String {
        switch label {
        case "Claude Code": "brain.head.profile"
        case "Codex": "chevron.left.forwardslash.chevron.right"
        case "Cursor", "OpenCode": "terminal.fill"
        default: "key.fill"
        }
    }

    private func agentColor(for label: String) -> Color {
        CPARoutingPresentation.agentColor(for: label)
    }
}
