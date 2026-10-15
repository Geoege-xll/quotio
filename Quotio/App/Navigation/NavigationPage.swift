import Foundation

// 全局导航类型归应用导航层；旧 quota、logs 和 workspace 兼容入口继续保留。
// 原始值和刷新入口归属不变，本次拆文件不会更改侧边栏或新增页面。

// MARK: - Navigation

nonisolated enum NavigationPage: String, CaseIterable, Identifiable {
    case dashboard = "Dashboard"
    // 统计功能统一为一个一级入口，具体用量／调用视图由页面内部的导航 Tab 管理。
    case analytics = "Analytics"
    case quota = "Quota"
    case providers = "Providers"
    case agents = "Agents"
    case agentManagement = "Agent Management"
    case apiKeys = "API Keys"
    case logs = "Logs"
    case settings = "Settings"
    case about = "About"

    var id: String { rawValue }

    /// 这些页面已经提供完整的额度／用量刷新入口，监控模式的侧栏不能再添加
    /// 第二个通用刷新按钮。旧 quota 路由与融合后的 providers 路由使用同一规则。
    var providesDataRefreshAction: Bool {
        switch self {
        case .dashboard, .analytics, .quota, .providers: true
        default: false
        }
    }

    var icon: String {
        switch self {
        // 路由中心：请求路由拓扑、网关调度中枢与多账号分发。
        case .dashboard: return "arrow.triangle.branch"
        case .analytics: return "chart.xyaxis.line"
        case .quota: return "chart.bar.fill"
        case .providers: return "person.2.badge.key"
        case .agents: return "terminal"
        case .agentManagement: return "slider.horizontal.2.square.on.square"
        case .apiKeys: return "key.horizontal"
        case .logs: return "doc.text"
        case .settings: return "gearshape"
        case .about: return "info.circle"
        }
    }

    static let workspace = NavigationPage.agentManagement
}
