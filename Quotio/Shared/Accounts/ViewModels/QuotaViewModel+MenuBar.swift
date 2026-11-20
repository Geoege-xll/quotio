//
//  QuotaViewModel+MenuBar.swift
//  Quotio
//

import Foundation

/// 菜单栏账号目录与额度投影，继续作用于应用持有的同一个 QuotaViewModel。
/// 目录候选、固定和显示均为原 ViewModel 的只读投影。通知继续经主类原入口合并。
extension QuotaViewModel {
    /// 同一份 CPA 目录在运行和离线时共享规范键，别名只用于映射既有缓存与固定项。
    var currentQuotaAccountAliases: [AIProvider: [String: String]] {
        MenuBarAccountCatalog.aliases(authFiles: authFiles, customProviders: configuredQuotaProviders)
    }

    /// 发布目录或刷新结果时统一缓存身份，确保页面、筛选计数和菜单栏看到同一份键。
    /// 额度和套餐采用同一份目录确认的映射，代理停止不会重键到本机登录。
    /// 此处只重排内存中的快照，不改写磁盘凭据或合并不同账号的额度数值。
    func reconcileAccountQuotaIdentities() {
        let aliases = currentQuotaAccountAliases
        // 即使当前目录没有额度别名，也继续迁移菜单固定项中的旧 Copilot 提供商名称。
        let selected = AuthFileIdentity.rekeyMenuBarItems(menuBarSettings.selectedItems, aliases: aliases)
        if selected != menuBarSettings.selectedItems {
            menuBarSettings.selectedItems = selected
        }
        guard !aliases.isEmpty else { return }
        providerQuotas = AuthFileIdentity.rekey(providerQuotas, aliases: aliases) { $0.lastUpdated > $1.lastUpdated }
        subscriptionInfos = AuthFileIdentity.rekey(subscriptionInfos, aliases: aliases) { _, _ in false }
    }

    /// 菜单弹出面板和固定项使用同一目录；已连接但尚无额度的身份仍可显示并固定。
    var menuBarAccountEntries: [MenuBarAccountCatalog.Entry] {
        MenuBarAccountCatalog.entries(authFiles: authFiles, importedIDEAccountKeys: importedIDEAccountKeys,
            customProviders: configuredQuotaProviders, warpTokens: WarpService.shared.tokens)
    }

    private var validMenuBarItems: [MenuBarQuotaItem] {
        menuBarAccountEntries.map(\.item)
    }

    func autoSelectMenuBarItems() {
        menuBarSettings.autoSelectNewAccounts(availableItems: validMenuBarItems)
    }

    func syncMenuBarSelection() {
        pruneMenuBarItems()
        autoSelectMenuBarItems()
        // 仅固定项／目录变化也通知原生状态栏，不依赖主窗口或下一次额度请求。
        notifyQuotaDataChanged()
    }

    /// 已离开确认目录和显式连接的账号不再参与菜单固定；现有额度缓存留给历史视图。
    func pruneMenuBarItems() {
        reconcileAccountQuotaIdentities()
        menuBarSettings.pruneInvalidItems(validItems: validMenuBarItems)
    }

    var menuBarQuotaItems: [MenuBarQuotaDisplayItem] {
        let settings = menuBarSettings
        guard settings.showQuotaInMenuBar else { return [] }
        
        let entries = Dictionary(uniqueKeysWithValues: menuBarAccountEntries.map { ($0.item, $0) })
        let aliases = currentQuotaAccountAliases
        let selectedItems = AuthFileIdentity.rekeyMenuBarItems(settings.selectedItems, aliases: aliases)
        let quotas = AuthFileIdentity.rekey(providerQuotas, aliases: aliases) { $0.lastUpdated > $1.lastUpdated }
        return selectedItems.compactMap { selectedItem in
            guard let entry = entries[selectedItem] else { return nil }
            let provider = entry.provider
            let data = quotas[provider]?[entry.accountKey]
            return MenuBarQuotaDisplayItem(
                id: selectedItem.id,
                providerSymbol: provider.menuBarSymbol,
                accountShort: entry.displayName,
                percentage: data.map { settings.quotaSummaryPercentage(for: provider, models: $0.models) } ?? -1,
                provider: provider,
                isForbidden: data?.isForbidden ?? false,
                quotaPair: settings.stackPairedQuotaMetrics
                    ? data.flatMap { MenuBarQuotaPair.resolve(for: provider, from: $0.models) } : nil
            )
        }
    }
}
