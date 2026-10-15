//
//  MonitorMetadataStore.swift
//  Quotio
//

import Foundation

/// 原账号元数据 actor；默认路径、私有 Payload 与全部加载／迁移／保存方法完整保留。
/// 禁用及删除仍经原同步世代校验与同一次原子写入，不开放存储或迁移旧配置键。
actor MonitorMetadataStore {
    static let shared = MonitorMetadataStore()

    private struct Payload: Codable {
        var accounts: [MonitorAccount] = []
        var disabledAccountIDs: Set<String> = []
    }

    private let url: URL

    init(url: URL? = nil) {
        self.url = url ?? FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Quotio/Monitor/accounts-v1.json")
    }

    func accounts() -> [MonitorAccount] { load().accounts }
    func disabledAccountIDs() -> Set<String> { load().disabledAccountIDs }

    func saveAccount(_ account: MonitorAccount) throws {
        var payload = load()
        payload.accounts.removeAll { $0.id == account.id }
        payload.accounts.append(account)
        try save(payload)
    }

    /// 与保险库使用同一授权世代。排队期间若已取消／重试，不能在旧 token 返回后补写账号元数据。
    /// 原 load／合并／原子落盘在同一同步锁段完成；其他既有保存调用继续走原无世代入口。
    func saveAccount(_ account: MonitorAccount, revision: UInt64, state: MonitorStateRevision) throws {
        try Task.checkCancellation()
        var entered = false
        var failure: Error?
        state.withCurrent(revision) {
            entered = true
            do { try saveAccount(account) } catch { failure = error }
        }
        guard entered else { throw CancellationError() }
        if let failure { throw failure }
    }

    func deleteAccount(_ accountID: String, revision: UInt64? = nil, state: MonitorStateRevision? = nil) throws {
        if let revision, let state {
            var failure: Error?
            state.withCurrent(revision, accountID: accountID) {
                do { try removeAccount(accountID) } catch { failure = error }
            }
            if let failure { throw failure }
        } else { try removeAccount(accountID) }
    }

    private func removeAccount(_ accountID: String) throws {
        var payload = load()
        payload.accounts.removeAll { $0.id == accountID }
        payload.disabledAccountIDs.remove(accountID)
        try save(payload)
    }

    func setDisabled(_ disabled: Bool, accountID: String) throws {
        try setDisabled(disabled, accountIDs: [accountID])
    }

    /// 多来源账号的禁用标记一次落盘；快速禁用再启用时，过期操作不能覆盖较新的选择。
    func setDisabled(_ disabled: Bool, accountIDs: Set<String>, revision: UInt64? = nil, state: MonitorStateRevision? = nil, mutationAccountID: String? = nil) throws {
        if let revision, let state {
            var failure: Error?
            state.withCurrent(revision, accountID: mutationAccountID) {
                do { try updateDisabled(disabled, accountIDs: accountIDs) } catch { failure = error }
            }
            if let failure { throw failure }
        } else {
            try updateDisabled(disabled, accountIDs: accountIDs)
        }
    }

    private func updateDisabled(_ disabled: Bool, accountIDs: Set<String>) throws {
        var payload = load()
        if disabled { payload.disabledAccountIDs.formUnion(accountIDs) }
        else { payload.disabledAccountIDs.subtract(accountIDs) }
        try save(payload)
    }

    private func load() -> Payload {
        guard let data = try? Data(contentsOf: url) else { return Payload() }
        if let payload = try? JSONDecoder().decode(Payload.self, from: data) {
            return payload
        }

        // Drop persisted Gemini CLI accounts after direct provider support is removed.
        guard var object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let accounts = object["accounts"] as? [[String: Any]] else { return Payload() }
        let removedIDs = Set(accounts.compactMap { account in
            account["provider"] as? String == "gemini-cli" ? account["id"] as? String : nil
        })
        guard !removedIDs.isEmpty else { return Payload() }

        object["accounts"] = accounts.filter { $0["provider"] as? String != "gemini-cli" }
        if let disabledIDs = object["disabledAccountIDs"] as? [String] {
            object["disabledAccountIDs"] = disabledIDs.filter { !removedIDs.contains($0) }
        }
        guard let migratedData = try? JSONSerialization.data(withJSONObject: object),
              let payload = try? JSONDecoder().decode(Payload.self, from: migratedData) else { return Payload() }
        try? save(payload)
        return payload
    }

    private func save(_ payload: Payload) throws {
        try SecureAtomicFileWriter.write(try JSONEncoder().encode(payload), to: url)
    }
}

