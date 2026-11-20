import Foundation

/// 账号页与菜单共用手动刷新计划。停机时只展示快照；代理就绪后先读目录，再刷新已有账号。
enum AccountRefreshStep: Equatable {
    case cpaDirectory, cpaQuotas

    static func plan(proxyRunning: Bool) -> [Self] {
        proxyRunning ? [.cpaDirectory, .cpaQuotas] : []
    }
}
