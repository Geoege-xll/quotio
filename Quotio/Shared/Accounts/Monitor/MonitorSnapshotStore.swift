//
//  MonitorSnapshotStore.swift
//  Quotio
//

import Foundation

/// 原监控快照 actor；私有 Payload、嵌套 Snapshot、路径及全部读写方法完整保留。
/// 额度与失败观察继续同次编码、同次原子提交，旧快照兼容字段及跨模式的精确账号删除语义不变。
actor MonitorSnapshotStore {
    private struct Payload: Codable {
        var quotas: [String: [String: ProviderQuotaData]]
        // 旧版快照只有 quotas；可选字段保证升级后仍能读取已有文件。
        var issues: [String: MonitorRefreshIssue]?
        var accountIssues: [String: [String: MonitorRefreshIssue]]?
    }

    struct Snapshot: Sendable {
        let quotas: [AIProvider: [String: ProviderQuotaData]]
        let issues: [AIProvider: MonitorRefreshIssue]
        let accountIssues: [QuotaAccountID: MonitorRefreshIssue]
    }

    private let url: URL

    init(url: URL? = nil) {
        if let url {
            self.url = url
        } else {
            let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            self.url = base
                .appendingPathComponent("Quotio", isDirectory: true)
                .appendingPathComponent("Monitor", isDirectory: true)
                .appendingPathComponent("snapshots-v1.json")
        }
    }

    func load() -> [AIProvider: [String: ProviderQuotaData]] {
        loadSnapshot().quotas
    }

    func loadSnapshot() -> Snapshot {
        guard let data = try? Data(contentsOf: url),
              let payload = try? JSONDecoder().decode(Payload.self, from: data) else {
            return Snapshot(quotas: [:], issues: [:], accountIssues: [:])
        }
        let quotas = payload.quotas.reduce(into: [AIProvider: [String: ProviderQuotaData]]()) { result, item in
            if let provider = AIProvider(rawValue: item.key) {
                result[provider] = item.value
            }
        }
        let issues = (payload.issues ?? [:]).reduce(into: [AIProvider: MonitorRefreshIssue]()) { result, item in
            if let provider = AIProvider(rawValue: item.key) {
                result[provider] = item.value
            }
        }
        let accountIssues = (payload.accountIssues ?? [:]).reduce(into: [QuotaAccountID: MonitorRefreshIssue]()) { result, item in
            guard let provider = AIProvider(rawValue: item.key) else { return }
            for (accountKey, issue) in item.value {
                result[QuotaAccountID(provider: provider, accountKey: accountKey)] = issue
            }
        }
        return Snapshot(quotas: quotas, issues: issues, accountIssues: accountIssues)
    }

    func store(_ quotas: [AIProvider: [String: ProviderQuotaData]], issues: [AIProvider: MonitorRefreshIssue] = [:], accountIssues: [QuotaAccountID: MonitorRefreshIssue] = [:], revision: UInt64? = nil, state: MonitorStateRevision? = nil) {
        if let revision, let state {
            state.withCurrent(revision) { write(quotas, issues: issues, accountIssues: accountIssues) }
        } else {
            write(quotas, issues: issues, accountIssues: accountIssues)
        }
    }

    private func write(_ quotas: [AIProvider: [String: ProviderQuotaData]], issues: [AIProvider: MonitorRefreshIssue], accountIssues: [QuotaAccountID: MonitorRefreshIssue]) {
        let encoded = quotas.reduce(into: [String: [String: ProviderQuotaData]]()) {
            $0[$1.key.rawValue] = $1.value
        }
        let encodedIssues = issues.reduce(into: [String: MonitorRefreshIssue]()) {
            $0[$1.key.rawValue] = $1.value
        }
        var encodedAccountIssues: [String: [String: MonitorRefreshIssue]] = [:]
        for (account, issue) in accountIssues {
            encodedAccountIssues[account.provider.rawValue, default: [:]][account.accountKey] = issue
        }
        // 额度和失败状态在同一次原子写入中发布，重启后不会把旧额度误认为最新成功结果。
        guard let data = try? JSONEncoder().encode(Payload(
            quotas: encoded, issues: encodedIssues, accountIssues: encodedAccountIssues
        )) else { return }
        do {
            try SecureAtomicFileWriter.write(data, to: url)
        } catch {
            Log.quota("Failed to persist Monitor snapshot: \(error.localizedDescription)")
        }
    }

    /// Drop a single account from the persisted snapshot, leaving every other entry as
    /// it is on disk.
    ///
    /// `store(_:)` replaces the whole file with the caller's in-memory quotas, which is
    /// only correct while Monitor mode is active. Deleting an imported IDE account is
    /// reachable from the other modes too, where the in-memory quotas belong to that
    /// mode, so the delete path needs this targeted removal instead (issue #213).
    ///
    /// - Returns: `true` when an entry was found and the file was rewritten.
    @discardableResult
    func removeAccount(provider: AIProvider, accountKey: String, revision: UInt64? = nil, state: MonitorStateRevision? = nil, mutationAccountID: String? = nil) -> Bool {
        if let revision, let state {
            var removed = false
            state.withCurrent(revision, accountID: mutationAccountID) { removed = removeAccountFromDisk(provider: provider, accountKey: accountKey) }
            return removed
        }
        return removeAccountFromDisk(provider: provider, accountKey: accountKey)
    }

    private func removeAccountFromDisk(provider: AIProvider, accountKey: String) -> Bool {
        let snapshot = loadSnapshot()
        var quotas = snapshot.quotas
        var accountQuotas = quotas[provider] ?? [:]
        var accountIssues = snapshot.accountIssues

        // Match the identity Monitor itself dedupes on (`MonitorAccount.deduplicationKey`):
        // the Monitor row carries a trimmed account key while the snapshot key is stored
        // verbatim, so an exact-only match could leave the entry behind.
        let normalized = accountKey.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        let matchingKeys = accountQuotas.keys.filter {
            $0 == accountKey || $0.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() == normalized
        }
        let matchingIssueKeys = accountIssues.keys.filter {
            $0.provider == provider && ($0.accountKey == accountKey
                || $0.accountKey.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() == normalized)
        }
        guard !matchingKeys.isEmpty || !matchingIssueKeys.isEmpty else { return false }

        for key in matchingKeys {
            accountQuotas.removeValue(forKey: key)
        }
        for key in matchingIssueKeys { accountIssues.removeValue(forKey: key) }
        if accountQuotas.isEmpty {
            quotas.removeValue(forKey: provider)
        } else {
            quotas[provider] = accountQuotas
        }
        // 失败状态按服务商记录，当前文件无法判断它是否属于被删账号；留待下次成功刷新清除，
        // 避免删除一个额度快照时抹掉同服务商其他账号仍在发生的失败。
        write(quotas, issues: snapshot.issues, accountIssues: accountIssues)
        return true
    }
}

