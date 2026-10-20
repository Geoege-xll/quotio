import Foundation

// 菜单候选、固定项解析和额度缓存重键共同复用的账号身份映射，按实际共享业务归位。
// 保留原模式目录选择、精确凭据、一对一旧别名、GLM 多 Key 与歧义拒绝规则；名称继续兼容原调用方。
// 本类型不保存账号、偏好或任务；原 QuotaViewModel 和菜单设置仍负责各自提交与生命周期。

/// 菜单栏只采用当前模式的账号目录。额度缓存仍可独立固定，但旧直读目录
/// 不能在 CPA 启动后重新加入已迁移的邮箱键，制造同账号的第二份固定项。
enum MenuBarAccountCatalog {
    /// 代理模式直接复用账号页的安全映射；监控模式仅兼容被当前目录确认的
    /// 显式旧身份字段，不根据显示名或“恰好一份成功额度”推测账号归属。
    static func aliases(mode: OperatingMode, proxyRunning: Bool, authFiles: [AuthFile],
                        directFiles: [DirectAuthFile], monitorAccounts: [MonitorAccount],
                        customProviders: [CustomProvider] = []) -> [AIProvider: [String: String]] {
        // GLM、DeepSeek 与 Moonshot 旧版按连接名称固定。只有名称唯一且连接仅含一个 Key 时才能迁移，
        // 多 Key 的旧名称无法证明具体凭据归属，继续保留独立缓存，不选首 Key 猜测。
        func extractCustomAliases(
            type: CustomProviderType,
            keyBuilder: (UUID, UUID) -> String
        ) -> [String: String] {
            let matched = customProviders.filter { $0.type == type }
            let canonicalKeys = Set(matched.flatMap { provider in provider.apiKeys.map {
                keyBuilder(provider.id, $0.id)
            } })
            var aliases: [String: String] = [:]
            for provider in matched where provider.isEnabled && provider.apiKeys.count == 1
                && !provider.name.isEmpty && !canonicalKeys.contains(provider.name)
                && matched.filter({ $0.name == provider.name }).count == 1 {
                aliases[provider.name] = keyBuilder(provider.id, provider.apiKeys[0].id)
            }
            return aliases
        }

        let glmAliases = extractCustomAliases(type: .glmCompatibility, keyBuilder: GLMQuotaFetcher.quotaAccountKey)
        let deepseekAliases = extractCustomAliases(type: .deepseekCompatibility, keyBuilder: DeepSeekQuotaFetcher.quotaAccountKey)
        let moonshotAliases = extractCustomAliases(type: .moonshotCompatibility, keyBuilder: MoonshotQuotaFetcher.quotaAccountKey)

        func mergeCustomAliases(into dict: inout [AIProvider: [String: String]]) {
            if !glmAliases.isEmpty { dict[.glm, default: [:]].merge(glmAliases) { current, _ in current } }
            if !deepseekAliases.isEmpty { dict[.deepseek, default: [:]].merge(deepseekAliases) { current, _ in current } }
            if !moonshotAliases.isEmpty { dict[.moonshot, default: [:]].merge(moonshotAliases) { current, _ in current } }
        }

        guard mode == .monitor else {
            var aliases = AuthFileIdentity.quotaAliases(mode: mode, proxyRunning: proxyRunning,
                authFiles: authFiles, directFiles: directFiles)
            mergeCustomAliases(into: &aliases)
            return aliases
        }
        let active = monitorAccounts.filter { !$0.isDisabled }
        let canonical = Dictionary(grouping: active, by: \.provider).mapValues { Set($0.map(\.accountKey)) }
        var claims: [AIProvider: [String: [String: String]]] = [:]
        for file in directFiles where [.codex, .copilot].contains(file.provider)
            && canonical[file.provider]?.contains(file.menuBarAccountKey) == true {
            // 同规范键多份文件也可能代表不同凭据，不能替它们认领旧 login。
            guard directFiles.filter({ $0.provider == file.provider && $0.menuBarAccountKey == file.menuBarAccountKey }).count == 1 else { continue }
            let legacy = (file.copilotUsesScopedIdentity ? [] : file.legacyIdentityKeys) + [file.filename,
                file.filename.hasSuffix(".json") ? String(file.filename.dropLast(5)) : file.filename]
                + (file.copilotUsesScopedIdentity ? [] : [file.email].compactMap { $0 })
            for key in legacy where !key.isEmpty && key != file.menuBarAccountKey {
                claims[file.provider, default: [:]][key, default: [:]][file.id] = file.menuBarAccountKey
            }
        }
        var result: [AIProvider: [String: String]] = claims.mapValues { providerClaims in
            providerClaims.compactMapValues { $0.count == 1 ? $0.values.first : nil }
        }.reduce(into: [:]) { result, entry in
            result[entry.key] = entry.value.filter { !canonical[entry.key, default: []].contains($0.key) }
        }
        mergeCustomAliases(into: &result)
        return result
    }

    static func items(mode: OperatingMode, proxyRunning: Bool, authFiles: [AuthFile],
                      directFiles: [DirectAuthFile], monitorAccounts: [MonitorAccount],
                      quotas: [AIProvider: [String: ProviderQuotaData]],
                      customProviders: [CustomProvider] = []) -> [MenuBarQuotaItem] {
        let aliases = aliases(mode: mode, proxyRunning: proxyRunning,
            authFiles: authFiles, directFiles: directFiles, monitorAccounts: monitorAccounts, customProviders: customProviders)
        var items = quotas.flatMap { provider, accounts in
            accounts.keys.map { MenuBarQuotaItem(provider: provider.rawValue,
                accountKey: aliases[provider]?[$0] ?? $0) }
        }
        if mode == .monitor {
            items += monitorAccounts.filter { !$0.isDisabled }.map {
                MenuBarQuotaItem(provider: $0.provider.rawValue, accountKey: $0.accountKey)
            }
        } else if proxyRunning {
            items += AuthFileIdentity.deduplicated(authFiles).compactMap { file in
                file.providerType.map { MenuBarQuotaItem(provider: $0.rawValue, accountKey: file.menuBarAccountKey) }
            }
        } else {
            // 同邮箱的多个直读文件没有可靠归属；只允许固定独立的缓存行，
            // 不能把其中任意一个文件当作该缓存的所有者。
            let counts = directFiles.reduce(into: [MenuBarQuotaItem: Int]()) {
                $0[MenuBarQuotaItem(provider: $1.provider.rawValue, accountKey: $1.menuBarAccountKey), default: 0] += 1
            }
            items += counts.filter { $0.value == 1 }.map(\.key)
        }
        // 连接存在不依赖额度请求成功。新 Key 尚无额度时固定项显示未知值，
        // 后续目录同步也不能把用户刚选择的 Key 裁掉，导致成功后无法自动恢复。
        let configured = customProviders.filter(\.isEnabled).flatMap { provider -> [MenuBarQuotaItem] in
            if provider.type == .glmCompatibility {
                let keys = provider.apiKeys.map { GLMQuotaFetcher.quotaAccountKey(providerID: provider.id, apiKeyID: $0.id) }
                return (keys.isEmpty ? [provider.name] : keys).map { MenuBarQuotaItem(provider: AIProvider.glm.rawValue, accountKey: $0) }
            }
            if provider.type == .clinePass { return [MenuBarQuotaItem(provider: AIProvider.clinePass.rawValue, accountKey: provider.name)] }
            if provider.type == .deepseekCompatibility {
                let keys = provider.apiKeys.map { DeepSeekQuotaFetcher.quotaAccountKey(providerID: provider.id, apiKeyID: $0.id) }
                return (keys.isEmpty ? [provider.name] : keys).map { MenuBarQuotaItem(provider: AIProvider.deepseek.rawValue, accountKey: $0) }
            }
            if provider.type == .moonshotCompatibility {
                let keys = provider.apiKeys.map { MoonshotQuotaFetcher.quotaAccountKey(providerID: provider.id, apiKeyID: $0.id) }
                return (keys.isEmpty ? [provider.name] : keys).map { MenuBarQuotaItem(provider: AIProvider.moonshot.rawValue, accountKey: $0) }
            }
            if provider.type == .minimaxCompatibility { return [MenuBarQuotaItem(provider: AIProvider.minimax.rawValue, accountKey: provider.name)] }
            return []
        }
        let counts = configured.reduce(into: [MenuBarQuotaItem: Int]()) { $0[$1, default: 0] += 1 }
        items += counts.filter { $0.value == 1 }.map(\.key)
        // 固定候选的顺序与额度更新顺序无关，不让字典遍历顺序挤掉用户预期的账号。
        return Array(Set(items)).sorted { $0.provider == $1.provider
            ? $0.accountKey < $1.accountKey : $0.provider < $1.provider }
    }

    /// 唯一的成功额度快照不代表唯一凭据。只接受精确键或当前目录确认的一对一
    /// 别名，不再按 accountDisplayName 猜测，避免同邮箱多凭据或不同认证目录串号。
    static func resolve(_ item: MenuBarQuotaItem, mode: OperatingMode, proxyRunning: Bool,
                        authFiles: [AuthFile], directFiles: [DirectAuthFile],
                        quotas: [AIProvider: [String: ProviderQuotaData]],
                        monitorAccounts: [MonitorAccount] = [], customProviders: [CustomProvider] = []) -> ProviderQuotaData? {
        guard let provider = item.aiProvider else { return nil }
        let aliases = aliases(mode: mode, proxyRunning: proxyRunning,
            authFiles: authFiles, directFiles: directFiles, monitorAccounts: monitorAccounts, customProviders: customProviders)
        let normalized = AuthFileIdentity.rekey(quotas, aliases: aliases) { $0.lastUpdated > $1.lastUpdated }
        let canonical = aliases[provider]?[item.accountKey] ?? item.accountKey
        return normalized[provider]?[canonical]
    }
}
