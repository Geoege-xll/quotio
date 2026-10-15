//
//  MonitorCredentialStore.swift
//  Quotio
//

import Foundation

/// 原监控凭据存储协议及默认拒绝 CAS 写回实现；签名、Sendable 和异步边界保持原样。
/// 协议默认实现不能用跨 await 的先读后写替代原子替换，生产写入仍由原保险库完成。
nonisolated protocol MonitorCredentialStore: Sendable {
    func accounts() async -> [MonitorAccount]
    func credential(for accountID: String) async -> MonitorOAuthCredential?
    func reloadLatest(accountID: String) async -> MonitorOAuthCredential?
    func save(_ credential: MonitorOAuthCredential, metadata: MonitorAccount) async throws
    func saveRefreshed(_ credential: MonitorOAuthCredential, replacing expected: MonitorOAuthCredential, accountID: String) async throws
    func delete(accountID: String) async
}


extension MonitorCredentialStore {
    /// 不支持原子替换的存储拒绝刷新写回；不能用有挂起点的“先读后写”假装 CAS。
    /// 生产保险库在同一 actor 内完成校验与替换，测试空存储也不会意外创建凭据。
    func saveRefreshed(_ credential: MonitorOAuthCredential, replacing expected: MonitorOAuthCredential, accountID: String) async throws {
        throw MonitorRuntimeError.credentialWriteFailed
    }
}

