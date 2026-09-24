import Foundation

/// 管理一次完整启动初始化的生命周期。代理进程启动后还有刷新、预热等异步步骤；
/// 用户停止时必须立即取消旧流程并允许再次启动，旧流程结束时也不能清除新流程的状态。
@MainActor
final class ProxyStartFlow {
    private var task: Task<Void, Never>?
    private var id: UUID?
    var isRunning: Bool { task != nil }

    func run(_ operation: @escaping @MainActor () async -> Void) async {
        guard task == nil else { return }
        let id = UUID()
        self.id = id
        let task = Task {
            defer {
                // 取消后可以已有新一轮启动，旧任务只负责清理自己持有的状态。
                if self.id == id {
                    self.task = nil
                    self.id = nil
                }
            }
            guard !Task.isCancelled else { return }
            await operation()
        }
        self.task = task
        await withTaskCancellationHandler {
            await task.value
        } onCancel: {
            task.cancel()
        }
    }

    func cancel() {
        task?.cancel()
        task = nil
        id = nil
    }
}
