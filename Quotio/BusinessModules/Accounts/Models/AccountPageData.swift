import Foundation

/// 融合页的账号目录拼装规则。这里只读取传入的快照，不访问磁盘、钥匙串或代理，
/// 使模式切换、同邮箱多凭据及纯额度缓存的兼容规则可以用离线回归测试验证。
enum AccountPageData {
    static func groupedAccounts(
        mode: OperatingMode,
        proxyRunning: Bool,
        authFiles: [AuthFile],
        directAuthFiles: [DirectAuthFile],
        monitorAccounts: [MonitorAccount],
        quotas: [AIProvider: [String: ProviderQuotaData]],
        customProviders: [CustomProvider],
        warpTokens: [WarpService.WarpToken],
        monitorStatus: (MonitorAccount) -> (status: String?, message: String?)
    ) -> [AIProvider: [AccountRowData]] {
        var groups: [AIProvider: [AccountRowData]] = [:]
        let currentAuthFiles = AuthFileIdentity.deduplicated(authFiles)
        let aliases = AuthFileIdentity.quotaAliases(mode: mode, proxyRunning: proxyRunning,
            authFiles: authFiles, directFiles: directAuthFiles)
        let quotas = AuthFileIdentity.rekey(quotas, aliases: aliases) { $0.lastUpdated > $1.lastUpdated }

        if mode == .localProxy && proxyRunning {
            // 代理运行时沿用 CPA 认证文件及其操作权限，忽略上一次直读列表。
            for file in currentAuthFiles {
                guard let provider = file.providerType else { continue }
                let data = AccountRowData.from(authFile: file, provider: provider)
                groups[provider, default: []].append(data)
            }
        } else if mode == .monitor {
            for account in monitorAccounts where ![.glm, .warp, .clinePass, .deepseek, .moonshot, .minimax].contains(account.provider) {
                let state = monitorStatus(account)
                let data = AccountRowData.from(
                    monitorAccount: account,
                    status: state.status,
                    statusMessage: state.message
                )
                groups[account.provider, default: []].append(data)
            }
        } else {
            // 代理停止后改用直读文件，避免旧代理 error 状态污染当前账号。
            for file in directAuthFiles {
                let data = AccountRowData.from(directAuthFile: file)
                groups[file.provider, default: []].append(data)
            }
        }

        // 自动检测来源保持原管理页规则；监控模式已从 monitorAccounts 获取同一批账号。
        for (provider, quotas) in quotas where mode != .monitor {
            if !provider.supportsManualAuth && provider != .glm && provider != .clinePass
                && provider != .deepseek && provider != .moonshot && provider != .minimax {
                for (accountKey, _) in quotas {
                    // 同一规范键已由当前连接目录提供时，不再添加第二份自动检测身份。
                    guard !groups[provider, default: []].contains(where: {
                        $0.quotaAccountKeys.contains(accountKey)
                    }) else { continue }
                    let data = AccountRowData.from(provider: provider, accountKey: accountKey)
                    groups[provider, default: []].append(data)
                }
            }
        }

        // GLM 继续使用配置 UUID 管理，但每个 API Key 有独立额度身份。
        // 在一个连接卡片下呈现所有 Key，避免名称键生成空卡或把多份额度误合并。
        for glmProvider in customProviders.filter({ $0.type == .glmCompatibility && $0.isEnabled }) {
            let keys = glmProvider.apiKeys.map {
                GLMQuotaFetcher.quotaAccountKey(providerID: glmProvider.id, apiKeyID: $0.id)
            }
            let data = AccountRowData(
                id: glmProvider.id.uuidString,
                provider: .glm,
                displayName: glmProvider.name.isEmpty ? "GLM" : glmProvider.name,
                menuBarAccountKey: keys.first ?? glmProvider.name,
                quotaAccountKeys: keys.isEmpty ? [glmProvider.name] : keys,
                source: .direct,
                status: "ready",
                statusMessage: nil,
                isDisabled: false,
                canDelete: true,
                canEdit: true
            )
            groups[.glm, default: []].append(data)
        }

        // 主流 OpenAI 兼容服务商（DeepSeek、Moonshot、MiniMax）沿用提供商配置的编辑／删除流程。
        for provider in customProviders.filter({ $0.type == .deepseekCompatibility && $0.isEnabled }) {
            let keys = provider.apiKeys.map {
                DeepSeekQuotaFetcher.quotaAccountKey(providerID: provider.id, apiKeyID: $0.id)
            }
            let data = AccountRowData(
                id: provider.id.uuidString,
                provider: .deepseek,
                displayName: provider.name.isEmpty ? "DeepSeek" : provider.name,
                menuBarAccountKey: keys.first ?? provider.name,
                quotaAccountKeys: keys.isEmpty ? [provider.name] : keys,
                source: .direct,
                status: "ready",
                statusMessage: nil,
                isDisabled: false,
                canDelete: true,
                canEdit: true
            )
            groups[.deepseek, default: []].append(data)
        }

        for provider in customProviders.filter({ $0.type == .moonshotCompatibility && $0.isEnabled }) {
            let keys = provider.apiKeys.map {
                MoonshotQuotaFetcher.quotaAccountKey(providerID: provider.id, apiKeyID: $0.id)
            }
            let data = AccountRowData(
                id: provider.id.uuidString,
                provider: .moonshot,
                displayName: provider.name.isEmpty ? "Kimi" : provider.name,
                menuBarAccountKey: keys.first ?? provider.name,
                quotaAccountKeys: keys.isEmpty ? [provider.name] : keys,
                source: .direct,
                status: "ready",
                statusMessage: nil,
                isDisabled: false,
                canDelete: true,
                canEdit: true
            )
            groups[.moonshot, default: []].append(data)
        }

        for provider in customProviders.filter({ $0.type == .minimaxCompatibility && $0.isEnabled }) {
            let data = AccountRowData(
                id: provider.id.uuidString,
                provider: .minimax,
                displayName: provider.name.isEmpty ? "MiniMax" : provider.name,
                menuBarAccountKey: provider.name,
                source: .direct,
                status: "ready",
                statusMessage: nil,
                isDisabled: false,
                canDelete: true,
                canEdit: true
            )
            groups[.minimax, default: []].append(data)
        }

        // ClinePass 沿用提供商配置的编辑／删除流程，并作为独立账号展示额度。
        for clinePassProvider in customProviders.filter({ $0.type == .clinePass && $0.isEnabled }) {
            let data = AccountRowData(
                id: clinePassProvider.id.uuidString,
                provider: .clinePass,
                displayName: clinePassProvider.name,
                menuBarAccountKey: clinePassProvider.name,
                source: .direct,
                status: "ready",
                statusMessage: nil,
                isDisabled: false,
                canDelete: true,
                canEdit: true
            )
            groups[.clinePass, default: []].append(data)
        }

        // Warp 继续使用 Token UUID 编辑或删除，不把名称误当成存储 ID。
        for warpToken in warpTokens.filter({ $0.isEnabled }) {
            let data = AccountRowData(
                id: warpToken.id.uuidString,
                provider: .warp,
                displayName: warpToken.name.isEmpty ? "Warp" : warpToken.name,
                menuBarAccountKey: warpToken.name,
                source: .direct,
                status: "ready",
                statusMessage: nil,
                isDisabled: false,
                canDelete: true,
                canEdit: true
            )
            groups[.warp, default: []].append(data)
        }

        // 非 Codex 的旧直读文件可能按邮箱保存额度键；同邮箱的多个文件无法仅凭
        // 该键确定缓存归属。保留各自管理行，取消有歧义的绑定，再单独呈现只读缓存。
        // 这条规则也覆盖任何来源的规范键碰撞，不能把一个额度桶复制到多个凭据下。
        for provider in Array(groups.keys) {
            let rows = groups[provider] ?? []
            let occurrences = rows.flatMap(\.quotaAccountKeys).reduce(into: [String: Int]()) {
                $0[$1, default: 0] += 1
            }
            groups[provider] = rows.map { row in
                var safeRow = row
                safeRow.quotaAccountKeys.removeAll { occurrences[$0, default: 0] > 1 }
                return safeRow
            }
        }

        // 原管理页只列出可管理连接，原额度页还会列出未匹配连接的缓存。
        // 按服务商和规范额度键补齐后，两类信息都可达；绝不能用邮箱归并不同凭据。
        for (provider, entries) in quotas {
            let existingKeys = Set(groups[provider, default: []].flatMap(\.quotaAccountKeys))
            for (key, quota) in entries where !existingKeys.contains(key) {
                let displayName = quota.accountDisplayName
                    ?? monitorAccounts.first { $0.provider == provider && $0.accountKey == key }?.displayName
                    ?? key
                groups[provider, default: []].append(AccountRowData(
                    id: "quota-cache:\(provider.rawValue):\(key)",
                    provider: provider,
                    displayName: displayName,
                    menuBarAccountKey: key,
                    source: .quotaCache,
                    status: nil,
                    statusMessage: nil,
                    isDisabled: false,
                    canDelete: false
                ))
            }
        }

        // 提供稳定的字典内顺序；同邮箱的 Plus/Team 等变体继续通过各自 ID 独立显示。
        return groups.mapValues { accounts in
            accounts.sorted {
                if $0.displayName == $1.displayName { return $0.id < $1.id }
                return $0.displayName.localizedStandardCompare($1.displayName) == .orderedAscending
            }
        }
    }
}
