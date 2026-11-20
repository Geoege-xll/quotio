import Foundation

/// 账号页只接收最近一次确认的 CPA 目录及用户显式添加的身份。
/// 额度快照由各行按规范键读取，因而历史额度本身不会增加账号、提供商或管理权限。
enum AccountPageData {
    static func groupedAccounts(
        hasCurrentCPAAccountDirectory: Bool,
        authFiles: [AuthFile],
        importedIDEAccountKeys: [AIProvider: Set<String>],
        customProviders: [CustomProvider],
        warpTokens: [WarpService.WarpToken]
    ) -> [AIProvider: [AccountRowData]] {
        var groups: [AIProvider: [AccountRowData]] = [:]
        for file in AuthFileIdentity.deduplicated(authFiles) {
            guard let provider = file.providerType else { continue }
            let data = AccountRowData.from(authFile: file, provider: provider,
                                           canManage: hasCurrentCPAAccountDirectory)
            groups[provider, default: []].append(data)
        }

        // 保留用户已导入的 IDE 连接。若规范键已归 CPA，管理权限跟同一 CPA 目录行走。
        for (provider, keys) in importedIDEAccountKeys where provider.isImportedFromLocalIDE {
            let cpaKeys = Set(groups[provider, default: []].flatMap(\.quotaAccountKeys))
            for key in keys.subtracting(cpaKeys) {
                groups[provider, default: []].append(AccountRowData.from(provider: provider, accountKey: key))
            }
        }

        // 按原配置 UUID 管理连接，并将每个已配置 Key 的额度段归到同一张卡片下。
        // 通用自定义配置继续由账号页的独立区块管理，避免一份连接出现两个入口。
        for configuration in customProviders where configuration.isEnabled {
            guard let provider = configuration.type.quotaProvider else { continue }
            let keys = configuration.quotaAccountKeys
            let data = AccountRowData(
                id: configuration.id.uuidString,
                provider: provider,
                displayName: configuration.name.isEmpty ? provider.displayName : configuration.name,
                menuBarAccountKey: keys.first ?? configuration.name,
                quotaAccountKeys: keys,
                source: .direct,
                status: "ready",
                statusMessage: nil,
                isDisabled: false,
                canDelete: true,
                canEdit: true
            )
            groups[provider, default: []].append(data)
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

        // 旧连接名或同名 Warp Token 可能碰撞。保留各自身份和管理入口，
        // 取消有歧义的额度绑定，避免把同一份额度挂到多个账号下。
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

        // 提供稳定的字典内顺序；同邮箱的 Plus/Team 等变体继续通过各自 ID 独立显示。
        return groups.mapValues { accounts in
            accounts.sorted {
                if $0.displayName == $1.displayName { return $0.id < $1.id }
                return $0.displayName.localizedStandardCompare($1.displayName) == .orderedAscending
            }
        }
    }
}
