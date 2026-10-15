//
//  MonitorCredentialVault.swift
//  Quotio
//

import Foundation

/// 原监控凭据保险库 actor，连同后端、共享实例与读取世代按完整类型迁移。
/// CAS 的读取、原凭据比较、同步替换与世代更新之间不新增挂起点；不改变删除／重授权后的拒绝写回规则。
/// 元数据仍由原注入实例保存，不增加钥匙串副本、任务或另一套凭据服务。
actor MonitorCredentialVault: MonitorCredentialStore {
    static let shared = MonitorCredentialVault()

    private let metadata: MonitorMetadataStore
    private var loadedGenerations: [String: String] = [:]
    /// 同步后端使读取和 CAS 处于同一个 actor 临界段；测试可替换为内存，不触碰真实钥匙串。
    nonisolated struct Backend: Sendable {
        let read: @Sendable (String) -> Data?
        let save: @Sendable (Data, String) -> Bool
        let compareAndSwap: @Sendable (Data, String, String) -> Bool
        let delete: @Sendable (String) -> Void
        static let live = Backend(
            read: { KeychainHelper.getMonitorCredential(account: $0) },
            save: { KeychainHelper.saveMonitorCredential($0, account: $1) },
            compareAndSwap: { KeychainHelper.compareAndSwapMonitorCredential($0, account: $1, expectedFingerprint: $2) },
            delete: { KeychainHelper.deleteMonitorCredential(account: $0) }
        )
    }
    private let backend: Backend

    init(metadata: MonitorMetadataStore = .shared, backend: Backend = .live) {
        self.metadata = metadata
        self.backend = backend
    }

    func accounts() async -> [MonitorAccount] {
        await metadata.accounts()
    }

    func credential(for accountID: String) -> MonitorOAuthCredential? {
        guard let data = backend.read(accountID) else { return nil }
        loadedGenerations[accountID] = MonitorIdentity.fingerprint(data.base64EncodedString())
        return try? JSONDecoder().decode(MonitorOAuthCredential.self, from: data)
    }

    func reloadLatest(accountID: String) -> MonitorOAuthCredential? {
        credential(for: accountID)
    }

    func save(_ credential: MonitorOAuthCredential, metadata account: MonitorAccount) async throws {
        try writeCredential(credential, accountID: account.id)
        try await self.metadata.saveAccount(account)
    }

    /// 手动授权的保存需要在保险库实际执行时复核会话；检查与同步钥匙串写入共用原世代锁。
    /// 不把异步 actor 调用放进锁内；元数据落盘由其原 actor 再次校验，取消后不能晚到新增账号行。
    func save(_ credential: MonitorOAuthCredential, metadata account: MonitorAccount,
              revision: UInt64, state: MonitorStateRevision) async throws {
        try Task.checkCancellation()
        var entered = false
        var failure: Error?
        state.withCurrent(revision) {
            entered = true
            do { try writeCredential(credential, accountID: account.id) } catch { failure = error }
        }
        guard entered else { throw CancellationError() }
        if let failure { throw failure }
        try await self.metadata.saveAccount(account, revision: revision, state: state)
    }

    /// 原新增／CAS、读取指纹更新保持同一同步段；旧保存入口及授权保护入口复用同一写入规则。
    private func writeCredential(_ credential: MonitorOAuthCredential, accountID: String) throws {
        let data = try JSONEncoder().encode(credential)
        let saved: Bool
        if let expected = loadedGenerations[accountID] {
            saved = backend.compareAndSwap(data, accountID, expected)
        } else {
            saved = backend.save(data, accountID)
        }
        guard saved else {
            throw MonitorRuntimeError.credentialWriteFailed
        }
        loadedGenerations[accountID] = MonitorIdentity.fingerprint(data.base64EncodedString())
    }

    func delete(accountID: String) async {
        backend.delete(accountID)
        loadedGenerations.removeValue(forKey: accountID)
        try? await metadata.deleteAccount(accountID)
    }

    /// 用户删除按账号排序，另一账号的变更不会取消本次删除；同账号较新的重加仍可使其失效。
    func delete(accountID: String, revision: UInt64, state: MonitorStateRevision) async {
        state.withCurrent(revision, accountID: accountID) {
            backend.delete(accountID)
            loadedGenerations.removeValue(forKey: accountID)
        }
        try? await metadata.deleteAccount(accountID, revision: revision, state: state)
    }

    /// 刷新只能替换仍存在且没有被重授权的原凭据，不能走主动添加账号的新增路径。
    /// 检查、CAS 和世代更新之间没有挂起点；不重写账号元数据，避免删除期间再次创建账号行。
    func saveRefreshed(_ credential: MonitorOAuthCredential, replacing expected: MonitorOAuthCredential, accountID: String) async throws {
        guard let currentData = backend.read(accountID),
              let current = try? JSONDecoder().decode(MonitorOAuthCredential.self, from: currentData),
              current == expected else { throw MonitorRuntimeError.credentialWriteFailed }
        let data = try JSONEncoder().encode(credential)
        guard backend.compareAndSwap(
            data, accountID, MonitorIdentity.fingerprint(currentData.base64EncodedString())
        ) else { throw MonitorRuntimeError.credentialWriteFailed }
        loadedGenerations[accountID] = MonitorIdentity.fingerprint(data.base64EncodedString())
    }
}

