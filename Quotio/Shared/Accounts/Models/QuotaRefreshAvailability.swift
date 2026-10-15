import Foundation

/// 获取额度刷新批次的真实槽位。等待放在调用方读取目录之后、发出额度请求之前，
/// 同一次同步 claim 同时检查并预约提供商，避免前置等待之后又被后台任务抢占。
/// 后台刷新遇到冲突直接合并跳过；明确的用户操作则等待，取消时不再预约。
@MainActor
enum QuotaRefreshAvailability {
    static func acquire(wait: Bool, claim: @MainActor () -> Bool) async -> Bool {
        while !Task.isCancelled {
            if claim() { return true }
            guard wait else { return false }
            do { try await Task.sleep(for: .milliseconds(100)) } catch { return false }
        }
        return false
    }
}
