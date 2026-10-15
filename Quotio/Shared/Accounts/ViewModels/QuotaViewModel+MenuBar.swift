//
//  QuotaViewModel+MenuBar.swift
//  Quotio
//

import Foundation

/// 菜单栏账号目录与额度投影，继续作用于应用持有的同一个 QuotaViewModel。
/// 身份归一、候选项、固定选择、裁剪和显示值沿用原方法及调用顺序；不创建第二份账号快照。
/// 跨文件调用只开放三个既有协作方法；目录辅助和额度解析仍在此文件内私有。
/// 通知合并通过主类原 notifyQuotaDataChanged 入口执行，原 Task 的持有与生命周期保持不变。
extension QuotaViewModel {
    /// 原目录身份规则的只读投影，同时供缓存重键和历史观测比较使用；不持有第二份映射状态。
    var currentQuotaAccountAliases: [AIProvider: [String: String]] {
        MenuBarAccountCatalog.aliases(mode: modeManager.currentMode,
            proxyRunning: proxyManager.proxyStatus.running, authFiles: authFiles,
            directFiles: directAuthFiles, monitorAccounts: monitorAccounts, customProviders: currentCustomProviders)
    }

    /// 发布目录或刷新结果时统一缓存身份，确保页面、筛选计数和菜单栏看到同一份键。
    /// CPA 运行时以当前凭据索引为准，停服后以直读目录为准；套餐采用相同映射。
    /// 此处只重排内存中的快照，不改写磁盘凭据或合并不同账号的额度数值。
    func reconcileAccountQuotaIdentities() {
        let aliases = currentQuotaAccountAliases
        // 提供商旧名称也要归一：监控模式没有额度别名时不能跳过 copilot 的迁移。
        let selected = AuthFileIdentity.rekeyMenuBarItems(menuBarSettings.selectedItems, aliases: aliases)
        if selected != menuBarSettings.selectedItems {
            menuBarSettings.selectedItems = selected
        }
        guard !aliases.isEmpty else { return }
        providerQuotas = AuthFileIdentity.rekey(providerQuotas, aliases: aliases) { $0.lastUpdated > $1.lastUpdated }
        subscriptionInfos = AuthFileIdentity.rekey(subscriptionInfos, aliases: aliases) { _, _ in false }
    }

    /// 候选与裁剪共用当前目录，不把上一模式的账号重新自动固定。
    private var currentCustomProviders: [CustomProvider] {
        #if DEBUG
        if let customProvidersForTesting { return customProvidersForTesting }
        #endif
        return CustomProviderService.shared.providers
    }

    private var validMenuBarItems: [MenuBarQuotaItem] {
        MenuBarAccountCatalog.items(mode: modeManager.currentMode,
            proxyRunning: proxyManager.proxyStatus.running, authFiles: authFiles,
            directFiles: directAuthFiles, monitorAccounts: monitorAccounts, quotas: providerQuotas,
            customProviders: currentCustomProviders)
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

    /// Remove menu bar items that no longer have valid quota data
    func pruneMenuBarItems() {
        reconcileAccountQuotaIdentities()
        menuBarSettings.pruneInvalidItems(validItems: validMenuBarItems)
    }

    var menuBarQuotaItems: [MenuBarQuotaDisplayItem] {
        let settings = menuBarSettings
        guard settings.showQuotaInMenuBar else { return [] }
        
        var items: [MenuBarQuotaDisplayItem] = []
        
        for selectedItem in settings.selectedItems {
            guard let provider = selectedItem.aiProvider else { continue }
            
            let data = resolveMenuBarQuota(for: selectedItem, provider: provider)
            items.append(MenuBarQuotaDisplayItem(
                id: selectedItem.id,
                providerSymbol: provider.menuBarSymbol,
                accountShort: data?.accountDisplayName ?? selectedItem.accountKey,
                percentage: data.map { settings.quotaSummaryPercentage(for: provider, models: $0.models) } ?? -1,
                provider: provider,
                isForbidden: data?.isForbidden ?? false,
                quotaPair: settings.stackPairedQuotaMetrics
                    ? data.flatMap { MenuBarQuotaPair.resolve(for: provider, from: $0.models) } : nil
            ))
        }
        
        return items
    }

    /// 精确凭据键及目录确认的旧身份都由同一安全映射解析，不依据显示名猜测。
    private func resolveMenuBarQuota(for item: MenuBarQuotaItem, provider: AIProvider) -> ProviderQuotaData? {
        MenuBarAccountCatalog.resolve(item, mode: modeManager.currentMode,
            proxyRunning: proxyManager.proxyStatus.running, authFiles: authFiles,
            directFiles: directAuthFiles, quotas: providerQuotas, monitorAccounts: monitorAccounts,
            customProviders: currentCustomProviders)
    }
}
