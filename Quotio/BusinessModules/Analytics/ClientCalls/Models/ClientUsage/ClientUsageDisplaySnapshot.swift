import Foundation

/// 页面只持有可展示的统计桶与来源状态，不传递完整事件和累计检查点。
/// 事实仍保存在 SQLite 中；切换筛选复用这些小型结果，不重新解析客户端日志。
nonisolated struct ClientUsageDisplaySnapshot: Sendable {
    var metadata = ClientUsageSnapshot()
    var buckets: [UsageBucket] = []
    /// Pi 未提供推理明细的日期，用于保留“未知”提示，避免为一个图标携带全部事件。
    var reasoningUnknownDays: [Date] = []

    // 保留展示调用端的 snapshot 名称；该快照仅含状态和采集时间，事实数组必须为空。
    var snapshot: ClientUsageSnapshot { metadata }
}
