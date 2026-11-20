import Foundation

/// 获取额度刷新批次的真实槽位。等待放在调用方读取目录之后、发出额度请求之前，
/// 同一次同步 claim 同时检查并预约提供商，避免前置等待之后又被后台任务抢占。
/// 机会性后台读取遇到冲突可合并跳过；用户操作、启动首轮和已到期的 CPA 定时批次显式等待。
/// 等待规则仍由调用方传入，取消时不再预约，也不释放其他批次持有的槽位。
@MainActor
enum QuotaRefreshAvailability {
    static func acquire(wait: Bool, isCurrent: @MainActor () -> Bool = { true },
                        claim: @MainActor () -> Bool) async -> Bool {
        // 会话失效时结束原等待，即使旧刷新仍未释放槽位；不允许旧点击在新运行会话重新预约。
        while !Task.isCancelled && isCurrent() {
            if claim() { return true }
            guard wait else { return false }
            do { try await Task.sleep(for: .milliseconds(100)) } catch { return false }
        }
        return false
    }
}
