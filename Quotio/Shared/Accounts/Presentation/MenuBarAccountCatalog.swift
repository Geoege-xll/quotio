import Foundation

/// 菜单身份来自最近确认的 CPA 目录，以及用户显式导入或配置的连接。
/// 额度只作为目录项的展示数据，不能让失效身份、旧缓存或本机其他会话重新成为菜单候选。
enum MenuBarAccountCatalog {
    struct Entry {
        let provider: AIProvider
        let accountKey: String
        let displayName: String

        var item: MenuBarQuotaItem { MenuBarQuotaItem(provider: provider.rawValue, accountKey: accountKey) }
    }

    static func aliases(authFiles: [AuthFile],
                        customProviders: [CustomProvider] = []) -> [AIProvider: [String: String]] {
        // GLM、DeepSeek 与 Moonshot 旧版按连接名称固定。只有名称唯一且连接仅含一个 Key 时才能迁移，
        // 多 Key 的旧名称无法证明具体凭据归属，旧记录留在历史中，由用户选择明确的 Key。
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

        // 冻结目录与在线目录采用同一 CPA 键空间，停机时也不读取固定的本机认证目录。
        var result = AuthFileIdentity.quotaAliases(mode: .localProxy, proxyRunning: true,
            authFiles: authFiles, directFiles: [])
        if !glmAliases.isEmpty { result[.glm, default: [:]].merge(glmAliases) { current, _ in current } }
        if !deepseekAliases.isEmpty { result[.deepseek, default: [:]].merge(deepseekAliases) { current, _ in current } }
        if !moonshotAliases.isEmpty { result[.moonshot, default: [:]].merge(moonshotAliases) { current, _ in current } }
        return result
    }

    static func items(authFiles: [AuthFile], importedIDEAccountKeys: [AIProvider: Set<String>] = [:],
                      customProviders: [CustomProvider] = [],
                      warpTokens: [WarpService.WarpToken] = []) -> [MenuBarQuotaItem] {
        entries(authFiles: authFiles, importedIDEAccountKeys: importedIDEAccountKeys,
                customProviders: customProviders, warpTokens: warpTokens).map(\.item)
    }

    static func entries(authFiles: [AuthFile], importedIDEAccountKeys: [AIProvider: Set<String>],
                        customProviders: [CustomProvider], warpTokens: [WarpService.WarpToken]) -> [Entry] {
        let cpaEntries: [Entry] = AuthFileIdentity.deduplicated(authFiles).compactMap { file in
            guard let provider = file.providerType else { return nil }
            return Entry(provider: provider, accountKey: file.menuBarAccountKey, displayName: file.email ?? file.name)
        }
        let cpaItems = Set(cpaEntries.map(\.item))
        let ideEntries = importedIDEAccountKeys.filter { $0.key.isImportedFromLocalIDE }.flatMap { provider, keys in
            keys.map { Entry(provider: provider, accountKey: $0, displayName: $0) }
                .filter { !cpaItems.contains($0.item) }
        }
        // 连接存在不依赖额度请求成功。新 Key 尚无额度时固定项显示未知值，
        // 后续目录同步也不能把用户刚选择的 Key 裁掉，导致成功后无法自动恢复。
        let configured = customProviders.filter(\.isEnabled).flatMap { configuration -> [Entry] in
            guard let provider = configuration.type.quotaProvider else { return [] }
            let keys = configuration.quotaAccountKeys
            let displayName = configuration.name.isEmpty ? provider.displayName : configuration.name
            return keys.map { Entry(provider: provider, accountKey: $0, displayName: displayName) }
        }
        let warpEntries = warpTokens.filter(\.isEnabled).map {
            Entry(provider: .warp, accountKey: $0.name, displayName: $0.name.isEmpty ? "Warp" : $0.name)
        }
        let candidates = cpaEntries + ideEntries + configured + warpEntries
        let counts = candidates.reduce(into: [MenuBarQuotaItem: Int]()) {
            $0[$1.item, default: 0] += 1
        }
        // 多份连接共用旧名称时，保留各自的账号页管理入口，菜单不猜测额度归属。
        return candidates.filter { counts[$0.item] == 1 }.sorted {
            if $0.provider == $1.provider {
                return $0.accountKey < $1.accountKey
            }
            return $0.provider.rawValue < $1.provider.rawValue
        }
    }

    /// 唯一的成功额度快照不代表唯一凭据。只接受精确键或当前目录确认的一对一
    /// 别名，不再按 accountDisplayName 猜测，避免同邮箱多凭据或不同认证目录串号。
    static func resolve(_ item: MenuBarQuotaItem, authFiles: [AuthFile],
                        quotas: [AIProvider: [String: ProviderQuotaData]],
                        customProviders: [CustomProvider] = []) -> ProviderQuotaData? {
        guard let provider = item.aiProvider else { return nil }
        let aliases = aliases(authFiles: authFiles, customProviders: customProviders)
        let normalized = AuthFileIdentity.rekey(quotas, aliases: aliases) { $0.lastUpdated > $1.lastUpdated }
        let canonical = aliases[provider]?[item.accountKey] ?? item.accountKey
        return normalized[provider]?[canonical]
    }
}

extension CustomProviderType {
    /// 只有具备既有额度规则的配置进入账号额度分组，通用配置仍在原自定义提供商区维护。
    var quotaProvider: AIProvider? {
        switch self {
        case .glmCompatibility: .glm
        case .deepseekCompatibility: .deepseek
        case .moonshotCompatibility: .moonshot
        case .minimaxCompatibility: .minimax
        case .clinePass: .clinePass
        default: nil
        }
    }
}

extension CustomProvider {
    /// 账号页及菜单使用同一规范键；多 Key 配置逐个保留原 UUID 生成规则。
    var quotaAccountKeys: [String] {
        let keys: [String]
        switch type {
        case .glmCompatibility:
            keys = apiKeys.map { GLMQuotaFetcher.quotaAccountKey(providerID: id, apiKeyID: $0.id) }
        case .deepseekCompatibility:
            keys = apiKeys.map { DeepSeekQuotaFetcher.quotaAccountKey(providerID: id, apiKeyID: $0.id) }
        case .moonshotCompatibility:
            keys = apiKeys.map { MoonshotQuotaFetcher.quotaAccountKey(providerID: id, apiKeyID: $0.id) }
        case .minimaxCompatibility, .clinePass:
            return [name]
        default:
            return []
        }
        return keys.isEmpty ? [name] : keys
    }
}
