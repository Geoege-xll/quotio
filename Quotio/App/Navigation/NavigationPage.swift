import Foundation

// 全局导航类型归应用导航层；旧 quota、logs 和 workspace 兼容入口继续保留。
// 旧原始值继续用于程序化导航。

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

    /// 侧栏固定呈现本地路由工作流；旧额度与日志仍由 App 详情路由接收。
    static let sidebarPages: [NavigationPage] = [
        .dashboard, .analytics, .providers, .agents, .agentManagement, .apiKeys, .settings, .about
    ]

    var titleKey: String {
        switch self {
        case .dashboard: "nav.dashboard"
        case .analytics: "nav.analytics"
        case .quota: "nav.quota"
        case .providers: "nav.accounts"
        case .agents: "nav.agents"
        case .agentManagement: "nav.agentManagement"
        case .apiKeys: "nav.apiKeys"
        case .logs: "nav.logs"
        case .settings: "nav.settings"
        case .about: "nav.about"
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
