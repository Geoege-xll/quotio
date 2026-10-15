//
//  MonitorStateRevision.swift
//  Quotio
//

import Foundation

/// 原同步世代宿主；锁、全局世代和逐账号版本仍由本类型唯一持有。
/// 校验与提交继续在原锁临界段内执行，保留独立账号命令排序和删除期间的磁盘提交边界。
/// 删除、禁用、重加与模式切换共用同步世代。MainActor 在首次挂起前即可使所有旧任务失效。
/// 锁同时保护磁盘提交边界，保证“检查仍有效”和实际写入之间不会插入删除操作。
nonisolated final class MonitorStateRevision: @unchecked Sendable {
    private let lock = NSLock()
    private var value: UInt64 = 0
    private var accountVersions: [String: UInt64] = [:]
    var current: UInt64 { lock.withLock { value } }
    /// 全局世代使旧刷新失效；账号世代只排列同一账号的用户命令，避免连续操作不同账号丢失。
    @discardableResult func advance(accountID: String? = nil) -> UInt64 {
        lock.withLock {
            value += 1
            if let accountID { accountVersions[accountID] = value }
            return value
        }
    }
    func isCurrent(_ expected: UInt64, accountID: String) -> Bool {
        lock.withLock { (accountVersions[accountID] ?? 0) <= expected }
    }
    func withCurrent(_ expected: UInt64, accountID: String? = nil, _ operation: () -> Void) {
        lock.withLock {
            let valid = accountID.map { (accountVersions[$0] ?? 0) <= expected } ?? (value == expected)
            if valid { operation() }
        }
    }
}

