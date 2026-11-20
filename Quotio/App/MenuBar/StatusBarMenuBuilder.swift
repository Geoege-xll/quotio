//
//  StatusBarMenuBuilder.swift
//  Quotio
//
//  Native NSMenu builder that matches MenuBarView layout:
//  - Header
//  - Proxy Info (Full Mode)
//  - Provider Segment Picker
//  - Account Cards (individual items)
//  - Actions
//

import AppKit
import SwiftUI

/// 菜单栏装配入口：原 builder 持有筛选控制器与菜单构建流程，身份由 ViewModel 的确认目录提供。
/// 组件仍由这些原方法创建；展开期间以原视图观察同一 VM，不复制账号状态或替换跟踪中的 NSMenuItem。
// MARK: - Status Bar Menu Builder

@MainActor
final class StatusBarMenuBuilder {
    
    private let viewModel: QuotaViewModel
    /// 正常装配复用应用历史服务；离线菜单夹具传 nil，禁止视图任务读取用户真实统计库。
    private let history: QuotaHistoryService?
    private var modeManager: OperatingModeManager { viewModel.modeManager }
    private let menuWidth: CGFloat = 360
    private var providerFilterController: StatusBarProviderFilterController?
    // Selected provider from UserDefaults (kept for compatibility)
    @AppStorage("menuBarSelectedProvider") private var selectedProviderRaw: String = ""
    
    init(viewModel: QuotaViewModel, history: QuotaHistoryService? = nil) {
        self.viewModel = viewModel
        self.history = history
    }
    
    // MARK: - Build Menu
    
    func buildMenu() -> NSMenu {
        let menu = makeMenu()
        providerFilterController = nil

        // 1. Header
        menu.addItem(buildHeaderItem())
        menu.addItem(NSMenuItem.separator())

        // 即使服务停止也保留操作行，用户可以从菜单重试启动。
        menu.addItem(buildNetworkInfoItem())
        menu.addItem(NSMenuItem.separator())

        // 3. Provider picker and account groups
        // 菜单结构按目录建一次。服务停止只更新快照内容及权限，不从本机 CLI 或额度反推账号。
        let accountGroups = Dictionary(grouping: viewModel.menuBarAccountEntries, by: \.provider)
        let providers = accountGroups.keys.sorted { $0.displayName < $1.displayName }
        if !providers.isEmpty {
            let controller = StatusBarProviderFilterController(
                selectedProvider: selectedProvider(from: providers),
                onSelectionChanged: { provider in
                    UserDefaults.standard.set(provider?.rawValue ?? "", forKey: "menuBarSelectedProvider")
                }
            )
            providerFilterController = controller
            let pickerView = MenuProviderPickerView(providers: providers, controller: controller)
            menu.addItem(viewItem(for: pickerView))
            menu.addItem(NSMenuItem.separator())

            // 所有提供商的卡片只构建一次；组标题和分隔线仅在“全部”筛选下显示。
            for (index, provider) in providers.enumerated() {
                let header = viewItem(for: MenuProviderSectionHeader(provider: provider))
                controller.register(header, scope: .allProvidersOnly)
                menu.addItem(header)
                let accounts = accountGroups[provider, default: []].map {
                    (accountKey: $0.accountKey, email: $0.displayName)
                }
                let ordered = Self.orderedAccounts(accounts, provider: provider) {
                    viewModel.hasCurrentCPAAccountDirectory && viewModel.isAntigravityAccountActive(email: $0)
                }
                for account in ordered {
                    let item = buildAccountCardItem(accountKey: account.accountKey, email: account.email,
                                                    provider: provider)
                    controller.register(item, scope: .provider(provider))
                    menu.addItem(item)
                }
                if index < providers.count - 1 {
                    let separator = NSMenuItem.separator()
                    controller.register(separator, scope: .allProvidersOnly)
                    menu.addItem(separator)
                }
            }

            menu.addItem(NSMenuItem.separator())
        } else {
            menu.addItem(buildEmptyStateItem())
            menu.addItem(NSMenuItem.separator())
        }
        
        // 4. Action items
        for item in buildActionItems() {
            menu.addItem(item)
        }
        
        activateProviderFilter(in: menu)
        return menu
    }

    func activateProviderFilter(in menu: NSMenu) {
        providerFilterController?.activate(in: menu)
    }
    
    // MARK: - Data Helpers
    
    private func selectedProvider(from providers: [AIProvider]) -> AIProvider? {
        guard !selectedProviderRaw.isEmpty,
              let provider = AIProvider(rawValue: selectedProviderRaw),
              providers.contains(provider) else {
            return nil
        }
        return provider
    }

    /// 菜单身份按名称排序，同名以规范键稳定区分。Antigravity 仍将已在 IDE 使用的账号置顶。
    nonisolated static func orderedAccounts(
        _ accounts: [(accountKey: String, email: String)],
        provider: AIProvider,
        isActiveInIDE: (String) -> Bool
    ) -> [(accountKey: String, email: String)] {
        let sorted = accounts.sorted { $0.email == $1.email ? $0.accountKey < $1.accountKey : $0.email < $1.email }

        guard provider == .antigravity else { return sorted }
        return AccountSorting.prioritizingActive(sorted) { isActiveInIDE($0.email) }
    }

    // MARK: - Header Item
    
    private func buildHeaderItem() -> NSMenuItem {
        // 读取发生在真实 SwiftUI body，刷新开始／完成能更新原标题项。
        viewItem(for: MenuLiveContent { MenuHeaderView(isLoading: self.viewModel.canRefreshAccountQuotas
            && self.viewModel.isLoadingQuotas) },
                 resizesToFitContent: true)
    }

    // MARK: - Network Info Item (Proxy + Tunnel combined)

    private func buildNetworkInfoItem() -> NSMenuItem {
        let proxyManager = viewModel.proxyManager
        let networkView = MenuNetworkInfoView(
            // 原生菜单只创建一次承载视图；状态必须在 SwiftUI body 中读取，
            // 才能订阅 Observable 的变化，而不是一直显示打开菜单时的布尔快照。
            proxyState: { [viewModel] in
                MenuProxyState(
                    port: proxyManager.port, isRunning: proxyManager.proxyStatus.running,
                    isInstalled: proxyManager.isBinaryInstalled, isInstalling: proxyManager.isDownloading,
                    isStarting: proxyManager.isStarting, isStopping: proxyManager.isStopping,
                    isRestarting: viewModel.isRestartingProxy, error: proxyManager.lastError
                )
            },
            onProxyRestart: { [weak viewModel] in
                Task { await viewModel?.restartProxy() }
            },
            onCopyProxyURL: {
                let url = "http://127.0.0.1:\(self.viewModel.proxyManager.port)"
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(url, forType: .string)
            },
            onTunnelToggle: { [weak viewModel] in
                guard let viewModel = viewModel else { return }
                Task {
                    await TunnelManager.shared.toggle(port: viewModel.proxyManager.port)
                }
            },
            onCopyTunnelURL: {
                TunnelManager.shared.copyURLToClipboard()
            }
        )
        // 目录复核失败原位显示在连接状态旁；避免为错误额外插入正在跟踪的原生菜单项。
        return viewItem(for: MenuLiveContent {
            VStack(spacing: 0) {
                networkView
                if let error = self.viewModel.lastCPAAccountDirectoryError {
                    Label(error, systemImage: "exclamationmark.triangle")
                        .font(.caption2)
                        .foregroundStyle(.orange)
                        .lineLimit(2)
                        .help(error)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.horizontal, 12)
                        .padding(.bottom, 4)
                }
            }
        }, resizesToFitContent: true)
    }

    // MARK: - Account Cards and Details

    private func buildAccountCardItem(
        accountKey: String,
        email: String,
        provider: AIProvider
    ) -> NSMenuItem {
        let sourceRevision = modeManager.revision
        let card = MenuLiveContent {
            // 只按同一提供商的精确账号键取最新快照；不使用同邮箱或另一账号的旧值填充。
            // 账号已移除时展示空状态，结构留到下次打开再调整，避免菜单跳位和旧数据复活。
            if self.modeManager.revision == sourceRevision,
               let entry = self.currentAccount(provider: provider, accountKey: accountKey) {
                let canManage = self.viewModel.hasCurrentCPAAccountDirectory
                MenuAccountCardView(
                    accountKey: accountKey, email: entry.displayName,
                    data: self.viewModel.providerQuotas[provider]?[accountKey], provider: provider,
                    subscriptionInfo: self.viewModel.subscriptionInfos[provider]?[accountKey],
                    isActiveInIDE: canManage && provider == .antigravity
                        && self.viewModel.isAntigravityAccountActive(email: entry.displayName),
                    onUseAccount: canManage && provider == .antigravity ? { [weak viewModel = self.viewModel] in
                        Self.showSwitchConfirmation(email: entry.displayName, viewModel: viewModel)
                    } : nil,
                    settings: self.viewModel.menuBarSettings
                )
            } else {
                MenuEmptyStateView()
            }
        }
        let item = viewItem(for: card, resizesToFitContent: true)
        // 原生标题不存储邮箱，隐私开关在菜单展开期间切换也不会留下未遮罩的辅助功能文本。
        item.title = provider.displayName
        item.submenu = buildAccountDetailSubmenu(accountKey: accountKey, email: email, provider: provider)
        return item
    }

    private func currentAccount(provider: AIProvider, accountKey: String) -> MenuBarAccountCatalog.Entry? {
        viewModel.menuBarAccountEntries.first { $0.provider == provider && $0.accountKey == accountKey }
    }

    /// 所有提供商采用同一明细入口；金额／次数／状态及未知额度沿用原 ModelQuota 语义。
    /// 一个动态承载项容纳额度桶变化，避免刷新时增删 AppKit 正在跟踪的子菜单项。
    private func buildAccountDetailSubmenu(accountKey: String, email: String, provider: AIProvider) -> NSMenu {
        // 本轮原生项固定来源世代；切模式后保持项身份，但不能展示新来源的同名额度，
        // 也不能让实时明细与已装配的历史动作分别指向不同模式。
        let sourceMode = modeManager.currentMode.rawValue
        let sourceRevision = modeManager.revision
        let submenu = makeMenu()
        let details = MenuLiveContent {
            let entry = self.modeManager.revision == sourceRevision
                ? self.currentAccount(provider: provider, accountKey: accountKey) : nil
            let current = entry == nil ? nil : self.viewModel.providerQuotas[provider]?[accountKey]
            MenuAccountDetailView(
                email: entry?.displayName ?? email,
                data: current, provider: provider,
                settings: self.viewModel.menuBarSettings,
                account: self.history == nil || self.modeManager.revision != sourceRevision ? nil
                    : QuotaHistoryAccount(mode: sourceMode, provider: provider, accountKey: accountKey),
                history: self.history
            )
        }
        submenu.addItem(viewItem(for: details, width: 380, resizesToFitContent: true))
        if provider == .codex {
            // Codex 原分析继续作为嵌套明细保留；无数据时显示原空状态，后续到达的分析原位可见。
            let analyticsItem = NSMenuItem(title: "usage.title".localized(), action: nil, keyEquivalent: "")
            let analyticsMenu = makeMenu()
            analyticsMenu.addItem(viewItem(for: MenuLiveContent {
                if self.modeManager.revision == sourceRevision,
                   self.currentAccount(provider: provider, accountKey: accountKey) != nil,
                   let analytics = self.viewModel.providerQuotas[provider]?[accountKey]?.analytics, !analytics.isEmpty {
                    AnalyticsDetailSection(analytics: analytics)
                } else {
                    MenuEmptyStateView()
                }
            }, width: 640, resizesToFitContent: true))
            analyticsItem.submenu = analyticsMenu
            submenu.addItem(.separator())
            submenu.addItem(analyticsItem)
        }
        if history != nil {
            submenu.addItem(.separator())
            let historyItem = NSMenuItem(title: "quota.history.open".localized(), action: #selector(MenuActionHandler.openQuotaHistory(_:)), keyEquivalent: "")
            historyItem.target = MenuActionHandler.shared
            historyItem.image = NSImage(systemSymbolName: "clock.arrow.circlepath", accessibilityDescription: nil)
            historyItem.representedObject = QuotaHistoryWindowContext(
                account: QuotaHistoryAccount(mode: sourceMode, provider: provider, accountKey: accountKey),
                displayName: email, sourceRevision: sourceRevision)
            submenu.addItem(historyItem)
        }
        return submenu
    }

    // MARK: - Switch Account Confirmation
    
    private static func showSwitchConfirmation(email: String, viewModel: QuotaViewModel?) {
        guard let viewModel, viewModel.hasCurrentCPAAccountDirectory else { return }
        
        let isIDERunning = viewModel.antigravitySwitcher.isIDERunning()
        
        let alert = NSAlert()
        alert.messageText = "antigravity.switch.dialog.title".localized()
        alert.informativeText = String(format: "antigravity.switch.dialog.message".localized(), email)
        
        if isIDERunning {
            alert.informativeText += "\n\n⚠️ " + "antigravity.switch.dialog.warning".localized()
        }
        
        alert.alertStyle = isIDERunning ? .warning : .informational
        alert.addButton(withTitle: "antigravity.switch.title".localized())
        alert.addButton(withTitle: "action.cancel".localized())
        
        let response = alert.runModal()
        
        if response == .alertFirstButtonReturn {
            Task { @MainActor in
                guard viewModel.hasCurrentCPAAccountDirectory else { return }
                await viewModel.switchAntigravityAccount(email: email)
                StatusBarManager.shared.rebuildMenuInPlace()
            }
        }
    }
    
    // MARK: - Empty State
    
    private func buildEmptyStateItem() -> NSMenuItem {
        let emptyView = MenuEmptyStateView()
        return viewItem(for: emptyView)
    }
    
    // MARK: - Action Items
    
    private func buildActionItems() -> [NSMenuItem] {
        let actionsView = MenuActionsView()
        let actions = viewItem(for: actionsView)
        guard history != nil else { return [actions] }

        // 菜单打开时不读库；旧账号选择只在用户打开原历史窗口后加载。
        let legacy = NSMenuItem(title: "quota.history.legacy".localized(),
            action: #selector(MenuActionHandler.openLegacyQuotaHistory), keyEquivalent: "")
        legacy.target = MenuActionHandler.shared
        legacy.image = NSImage(systemSymbolName: "clock.arrow.circlepath", accessibilityDescription: nil)
        return [legacy, .separator(), actions]
    }
    
    // MARK: - Helpers

    private func makeMenu() -> NSMenu {
        let menu = NSMenu()
        menu.autoenablesItems = false
        menu.appearance = AppearanceManager.shared.appearanceMode.appKitAppearance
        return menu
    }
    
    private func viewItem<V: View>(for view: V, width: CGFloat? = nil, resizesToFitContent: Bool = false) -> NSMenuItem {
        let effectiveWidth = width ?? menuWidth
        let appearanceMode = AppearanceManager.shared.appearanceMode
        let rootView = view
            .frame(width: effectiveWidth)
            .environment(viewModel)
        let hostingView = makeMenuItemHostingView(rootView: rootView, resizesToFitContent: resizesToFitContent)
        hostingView.appearance = appearanceMode.appKitAppearance
        hostingView.setFrameSize(hostingView.intrinsicContentSize)
        
        let item = NSMenuItem()
        item.view = hostingView
        return item
    }
}

/// 将读取延迟到 body，才能让 Observation 追踪当前账号的额度／套餐变化。
/// 闭包不保存第二份快照，不创建任务；原 NSHostingView 和其局部 @State 继续复用。
private struct MenuLiveContent<Content: View>: View {
    @ViewBuilder let content: () -> Content
    var body: some View { content() }
}
