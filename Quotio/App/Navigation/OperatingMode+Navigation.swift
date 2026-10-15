import Foundation

/// App 根据共享运行模式决定页面集合，保留原可见页面、顺序与日志过滤规则。
/// 扩展只读取原模式，不复制偏好、修改 revision 或建立另一个运行模式宿主。
extension OperatingMode {
    /// Sidebar navigation pages visible in this mode
    var visiblePages: [NavigationPage] {
        switch self {
        case .monitor:
            // 统一统计入口在监控模式也可用：可查看已保存的 CPA 历史，或按需进入本地分析。
            return [.dashboard, .analytics, .providers, .settings, .about]
        case .localProxy:
            // 日志归属设置中的诊断工具，不再作为一级侧栏页面。
            return [.dashboard, .analytics, .providers, .agents, .apiKeys, .settings, .about]
        }
    }
}

/// 原 manager 的导航查询留在 App；currentMode 的私有 setter 和所有状态写入仍归共享主类型。
/// 成员正文不变，只通过既有只读 getter 查询页面，不扩大任何访问权限。
extension OperatingModeManager {
    /// Check if a page should be visible in current mode
    func isPageVisible(_ page: NavigationPage, loggingEnabled: Bool = true) -> Bool {
        var pages = currentMode.visiblePages
        if !loggingEnabled {
            pages.removeAll { $0 == .logs }
        }
        return pages.contains(page)
    }
}
