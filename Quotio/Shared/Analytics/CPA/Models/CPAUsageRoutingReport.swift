import Foundation

/// 共享 CPA 事件库、账本和消费服务返回的路由查询契约，由路由页面只读消费。
/// 查询实现仍在原服务：本类型仅保存原结果，不查询数据库、不创建消费任务、不承担动画时钟。
/// arrivalEvents 的 nil 兼容、统计范围与空快照时间规则保持原样，页面活动和光流模型留在 Dashboard。
/// 路由中心的只读投影只包含真实用量明细。计数单位是上游执行记录，
/// 不混入无法还原账号、取消状态或尝试链的旧日汇总，也不推断客户端最终结果。
nonisolated struct CPARoutingSnapshot: Sendable {
    var events: [CPAUsageEvent] = []
    /// 采集顺序中的近期候选，仅供舞台识别迟到执行；列表仍使用 events 的时间顺序。
    /// nil 兼容现有内存快照夹具，生产查询会给出有界候选，不保存全日事件。
    var arrivalEvents: [CPAUsageEvent]?
    var executions = 0
    var failures = 0
    var canceled = 0
    let start: Date
    let end: Date

    static func empty(now: Date, calendar: Calendar = .current) -> Self {
        Self(start: calendar.startOfDay(for: now), end: now)
    }
}
