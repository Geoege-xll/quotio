//
//  MonitorRefreshIssue.swift
//  Quotio
//

import Foundation

/// 原监控失败观察值；保留错误文案与发生时间编码，继续由原协调器及快照宿主创建和提交。
nonisolated struct MonitorRefreshIssue: Codable, Hashable, Sendable {
    let message: String
    let occurredAt: Date
}

