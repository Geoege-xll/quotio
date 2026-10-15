import Foundation

/// 账号页与菜单栏执行同一份全量刷新计划。目录先刷新，额度后刷新；
/// Grok／Devin 的补充路径属于账号服务，不能只留在某个页面的私有按钮里。
enum AccountRefreshStep: Equatable {
    case directDirectory, monitorQuotas, cpaDirectory, cpaQuotas, localQuotas
    case provider(AIProvider)

    static func plan(mode: OperatingMode, proxyRunning: Bool) -> [Self] {
        if mode == .monitor { return [.monitorQuotas] }
        let main: [Self] = proxyRunning ? [.cpaDirectory, .cpaQuotas] : [.directDirectory, .localQuotas]
        return main + [.provider(.grok), .provider(.devin)]
    }
}
