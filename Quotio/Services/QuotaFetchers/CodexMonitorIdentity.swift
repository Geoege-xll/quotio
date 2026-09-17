import Foundation

/// 监控模式把同一 account ID 的凭据来源看成一个逻辑账号；源 ID 始终保留用于禁用和删除。
/// 只在明确 account ID 相同时归并，不能仅凭 email 合并两个不同的 ChatGPT 组织/账号。
nonisolated struct CodexMonitorSource: Sendable {
    enum Kind: Sendable, Equatable {
        case vault
        case keychain
        case file(String)
        case legacy(String)
    }
    let account: MonitorAccount
    let accountID: String?
    let kind: Kind
    var isReadable: Bool = true

    var identity: String {
        if let accountID, !accountID.isEmpty { return "id:" + accountID }
        return "key:" + account.accountKey.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
    }
}

nonisolated struct CodexMonitorGroup: Sendable {
    let account: MonitorAccount
    let sources: [CodexMonitorSource]
    let aliases: Set<String>
    /// 禁用标识绑定不可变的 account ID，邮箱从唯一变为多组织歧义时也不会意外重新启用。
    var stableDisabledID: String {
        // 自有账号的 metadata ID 本身稳定，保险库锁定时仍能用同一标识禁用/启用。
        sources.first(where: { $0.account.canDelete })?.account.id ?? Self.disabledID(for: sources[0].identity)
    }
    static func disabledID(for identity: String) -> String {
        "monitor-codex-identity-" + MonitorIdentity.fingerprint(identity)
    }

    /// 保持来源优先级：自有保险库、原生来源、兼容文件。若有唯一 legacy 键则沿用，兼容旧菜单选择。
    static func resolve(_ sources: [CodexMonitorSource], disabledIDs: Set<String>) -> [Self] {
        let grouped = Dictionary(grouping: sources, by: \.identity)
        let rawKeyOwners = Dictionary(grouping: sources, by: { $0.account.accountKey.lowercased() })
            .mapValues { Set($0.map(\.identity)) }
        var resolved: [Self] = []
        for identity in grouped.keys.sorted() {
            let members = grouped[identity]!.sorted {
                if $0.account.source.priority != $1.account.source.priority {
                    return $0.account.source.priority > $1.account.source.priority
                }
                return ($0.account.credentialReference ?? $0.account.id) < ($1.account.credentialReference ?? $1.account.id)
            }
            guard let preferred = members.first else { continue }
            let legacyKeys = Set(members.compactMap { source -> String? in
                if case .legacy = source.kind { return source.account.accountKey }
                return nil
            })
            var key = legacyKeys.count == 1 ? legacyKeys.first! : preferred.account.accountKey
            // 同一个 email 对应多个明确 ID 时，用 ID 区分额度行；显示名仍保留 email。
            let ambiguous = (rawKeyOwners[key.lowercased()]?.count ?? 0) > 1
            if ambiguous, let accountID = preferred.accountID { key = accountID }
            let canonicalID = MonitorAccount.make(provider: .codex, accountKey: key, source: preferred.account.source).id
            let id = ambiguous && !preferred.account.canDelete ? canonicalID : preferred.account.id
            let disabled = disabledIDs.contains(Self.disabledID(for: identity)) || disabledIDs.contains(canonicalID) || members.contains { source in
                // 旧版由 email 生成的 ID 在多组织间有歧义，不能据此禁用另一个明确账号。
                let unambiguous = (rawKeyOwners[source.account.accountKey.lowercased()]?.count ?? 0) <= 1
                return source.account.isDisabled || ((unambiguous || source.account.canDelete) && disabledIDs.contains(source.account.id))
            }
            let account = MonitorAccount(id: id, provider: .codex, accountKey: key,
                                         displayName: preferred.account.displayName, source: preferred.account.source,
                                         credentialReference: preferred.account.credentialReference,
                                         canDelete: preferred.account.canDelete, isDisabled: disabled)
            let aliases = Set(members.map { $0.account.accountKey }.filter {
                (rawKeyOwners[$0.lowercased()]?.count ?? 0) <= 1
            }).union([key]).union(members.compactMap(\.accountID))
            resolved.append(Self(account: account, sources: members, aliases: aliases))
        }
        return resolved.sorted { $0.account.accountKey < $1.account.accountKey }
    }

    /// 把成功/缓存结果统一到当前身份。只接受仍存在的来源，删除来源的缓存不会被旧邮箱保留。
    static func reconcile(_ quotas: [String: ProviderQuotaData], groups: [Self]) -> [String: ProviderQuotaData] {
        // 保险库锁定属于身份暂不可读，不能据此认定旧缓存账号已删除。解锁后的完整发现再归并。
        var result = groups.contains { !$0.account.isDisabled && $0.sources.contains { !$0.isReadable } } ? quotas : [:]
        // 其他账号锁定不能替已确认换号的邮箱保留旧额度：可读来源明确占用该键时，身份必须相符。
        for group in groups where group.sources.contains(where: \.isReadable) {
            let identities = Set(group.sources.map(\.identity))
            for alias in group.aliases {
                if let identity = result[alias]?.monitorAccountIdentity, !identities.contains(identity) {
                    result.removeValue(forKey: alias)
                }
            }
        }
        for group in groups where group.account.isDisabled {
            let identities = Set(group.sources.map(\.identity))
            result = result.filter { entry in
                !group.aliases.contains(entry.key)
                    && !(entry.value.monitorAccountIdentity.map { identities.contains($0) } ?? false)
            }
        }
        for group in groups where !group.account.isDisabled {
            let identities = Set(group.sources.map(\.identity))
            for (alias, storedQuota) in quotas {
                // 新快照以实际身份为准；旧快照没有标记时才回退到无歧义别名。
                if let identity = storedQuota.monitorAccountIdentity {
                    guard identities.contains(identity) else { continue }
                } else {
                    guard group.aliases.contains(alias) else { continue }
                }
                var quota = storedQuota
                let key = group.account.accountKey
                if result[key].map({ $0.lastUpdated > quota.lastUpdated }) == true { continue }
                if quota.accountDisplayName == nil { quota.accountDisplayName = group.account.displayName }
                result[key] = quota
            }
        }
        return result
    }
}
