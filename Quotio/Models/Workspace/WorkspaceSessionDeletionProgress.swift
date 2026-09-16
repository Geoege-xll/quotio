import Foundation

/// 一次会话删除的展示状态。计数以提交给服务的删除项为单位，父会话及其后代只计一项；
/// 只有服务返回结果后才推进数量，不根据时间推算百分比，也不把容量统计扫描计入删除。
nonisolated struct WorkspaceSessionDeletionProgress: Identifiable, Equatable, Sendable {
    enum Phase: Equatable, Sendable {
        case preparing
        case deleting
        case refreshing
        case finished
    }

    let id = UUID()
    let startedAt: Date
    var finishedAt: Date?
    var phase: Phase = .preparing
    var totalCount = 0
    var currentSessionTitle = ""
    var currentAgentName = ""
    var includesDescendants = false
    var result = WorkspaceOperationResult()

    init(startedAt: Date = Date()) { self.startedAt = startedAt }

    var processedCount: Int { result.succeededCount + result.failures.count }
    var isFinished: Bool { phase == .finished }

    var title: String {
        switch phase {
        case .preparing: "正在准备删除"
        case .deleting: "正在删除会话"
        case .refreshing: "正在更新会话列表"
        case .finished: result.succeededCount == 0 ? "会话删除失败" : "部分会话删除失败"
        }
    }

    var detail: String {
        switch phase {
        case .preparing: "正在整理要删除的会话，请稍候。"
        case .deleting: "耗时取决于会话数量和文件大小，请稍候。"
        case .refreshing: "删除操作已处理，正在同步列表和会话详情。"
        case .finished: "请查看下方原因，关闭后可刷新列表确认会话状态。"
        }
    }

    /// 计时只负责反馈持续活动，结束后固定在真实完成时间；不触发额外扫描或网络请求。
    func elapsedText(at date: Date) -> String {
        let seconds = max(0, Int((finishedAt ?? date).timeIntervalSince(startedAt)))
        if seconds < 60 { return "已用时 \(seconds) 秒" }
        return "已用时 \(seconds / 60) 分 \(seconds % 60) 秒"
    }
}
