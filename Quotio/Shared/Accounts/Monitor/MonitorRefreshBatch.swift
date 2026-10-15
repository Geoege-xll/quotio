//
//  MonitorRefreshBatch.swift
//  Quotio
//

import Foundation

/// 原启动／刷新批次值；账号、额度、提供商错误与精确账号错误仍通过同一批次传递，不复制状态宿主。
nonisolated struct MonitorRefreshBatch: Sendable {
    var accounts: [MonitorAccount]
    var quotas: [AIProvider: [String: ProviderQuotaData]]
    var issues: [AIProvider: MonitorRefreshIssue]
    var accountIssues: [QuotaAccountID: MonitorRefreshIssue]
}

