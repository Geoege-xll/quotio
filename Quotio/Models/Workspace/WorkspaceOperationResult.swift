import Foundation

/// 批量操作的实际完成结果。只有完成磁盘或数据库提交的项目才计入成功，
/// 失败项目保留原因，调用者不能再用“计划处理的数量”代替成功数量。
public nonisolated struct WorkspaceOperationResult: Sendable, Equatable {
    public var succeededCount: Int
    public var freedBytes: Int64
    public var failures: [String]

    public init(succeededCount: Int = 0, freedBytes: Int64 = 0, failures: [String] = []) {
        self.succeededCount = succeededCount
        self.freedBytes = freedBytes
        self.failures = failures
    }

    /// 兼容原先单一 throws 接口时，仍须将部分失败传回调用者。
    public func throwIfFailed() throws {
        guard !failures.isEmpty else { return }
        throw NSError(domain: "WorkspaceOperation", code: 1, userInfo: [
            NSLocalizedDescriptionKey: "已完成 \(succeededCount) 项，\(failures.count) 项失败：\n" + failures.joined(separator: "\n")
        ])
    }
}
