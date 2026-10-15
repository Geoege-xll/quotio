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

/// 菜单栏装配入口：继续由原 builder 持有账号模型、筛选控制器、检测缓存与菜单构建流程。
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
    private let agentDetectionService = AgentDetectionService()
    
    // Cached agent statuses for filtering
    private var cachedAgentStatuses: [CLIAgent: Bool] = [:]
    private var lastAgentCacheTime: Date?
    private let agentCacheValidity: TimeInterval = 300 // 5 minutes
    
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

        // 2. Network info (Proxy + Tunnel) - Local Proxy Mode only
        if modeManager.isLocalProxyMode {
            menu.addItem(buildNetworkInfoItem())
            menu.addItem(NSMenuItem.separator())
        }

        // 3. Provider picker and account groups
        let providers = providersWithData
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
                let accounts = accountsForProvider(provider)
                if accounts.isEmpty {
                    let empty = buildEmptyStateItem()
                    controller.register(empty, scope: .provider(provider))
                    menu.addItem(empty)
                } else {
                    for account in accounts {
                        let item = buildAccountCardItem(
                            accountKey: account.accountKey, email: account.email,
                            provider: provider
                        )
                        controller.register(item, scope: .provider(provider))
                        menu.addItem(item)
                    }
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
    
    private var providersWithData: [AIProvider] {
        var providers = Set<AIProvider>()
        
        // From direct auth files (scanned from filesystem - available immediately)
        for file in viewModel.directAuthFiles {
            providers.insert(file.provider)
        }
        
        // From quota data (available after API calls complete)
        for (provider, accountQuotas) in viewModel.providerQuotas {
            if !accountQuotas.isEmpty {
                providers.insert(provider)
            }
        }

        if modeManager.isMonitorMode {
            providers.formUnion(Self.monitorProviders(viewModel.monitorAccounts))
        }
        
        return Self.filterProviders(
            providers,
            isMonitorMode: modeManager.isMonitorMode,
            isCLIInstalled: isCLIInstalled
        )
    }

    nonisolated static func monitorProviders(_ accounts: [MonitorAccount]) -> Set<AIProvider> {
        Set(accounts.lazy.filter { !$0.isDisabled }.map(\.provider))
    }

    nonisolated static func filterProviders(
        _ providers: Set<AIProvider>,
        isMonitorMode: Bool,
        isCLIInstalled: (CLIAgent) -> Bool
    ) -> [AIProvider] {
        let sorted = providers.sorted { $0.displayName < $1.displayName }
        guard !isMonitorMode else { return sorted }
        return sorted.filter { provider in
            guard let agent = provider.cliAgent else { return true }
            return isCLIInstalled(agent)
        }
    }
    
    private func isCLIInstalled(_ agent: CLIAgent) -> Bool {
        // Check cache first
        if let lastCache = lastAgentCacheTime,
           Date().timeIntervalSince(lastCache) < agentCacheValidity,
           let cached = cachedAgentStatuses[agent] {
            return cached
        }
        
        // Check if we have cached data from QuotaViewModel
        if let statuses = viewModel.agentSetupViewModel.agentStatuses as [AgentStatus]?,
           !statuses.isEmpty,
           let status = statuses.first(where: { $0.agent == agent }) {
            cachedAgentStatuses[agent] = status.installed
            lastAgentCacheTime = Date()
            return status.installed
        }
        
        // Fallback: synchronous binary check
        let isInstalled = checkBinaryExists(names: agent.binaryNames)
        cachedAgentStatuses[agent] = isInstalled
        lastAgentCacheTime = Date()
        return isInstalled
    }
    
    private func checkBinaryExists(names: [String]) -> Bool {
        let fileManager = FileManager.default
        let home = fileManager.homeDirectoryForCurrentUser.path
        
        let commonPaths = [
            "/usr/local/bin",
            "/opt/homebrew/bin",
            "/usr/bin",
            "\(home)/.local/bin",
            "\(home)/.cargo/bin",
            "\(home)/.bun/bin",
            "\(home)/.deno/bin",
            "\(home)/.npm-global/bin",
            "\(home)/.volta/bin",
            "\(home)/.asdf/shims",
            "\(home)/.local/share/mise/shims"
        ]
        
        for name in names {
            for basePath in commonPaths {
                let fullPath = "\(basePath)/\(name)"
                if fileManager.isExecutableFile(atPath: fullPath) {
                    return true
                }
            }
        }
        return false
    }
    
    private func selectedProvider(from providers: [AIProvider]) -> AIProvider? {
        guard !selectedProviderRaw.isEmpty,
              let provider = AIProvider(rawValue: selectedProviderRaw),
              providers.contains(provider) else {
            return nil
        }
        return provider
    }

    private func accountsForProvider(
        _ provider: AIProvider
    ) -> [(accountKey: String, email: String, data: ProviderQuotaData)] {
        guard let quotas = viewModel.providerQuotas[provider] else { return [] }
        return Self.orderedAccounts(quotas, provider: provider) {
            viewModel.isAntigravityAccountActive(email: $0)
        }
    }

    /// Orders the menu-bar account rows for `provider`: alphabetical by email, with the
    /// account currently in use floated to the top.
    ///
    /// `isActiveInIDE` is only consulted for Antigravity, the single provider that exposes
    /// an "in use" signal, so the ordering is driven by exactly the same predicate that
    /// `buildAccountCardItem` uses to render the active badge on the same row.
    nonisolated static func orderedAccounts(
        _ quotas: [String: ProviderQuotaData],
        provider: AIProvider,
        isActiveInIDE: (String) -> Bool
    ) -> [(accountKey: String, email: String, data: ProviderQuotaData)] {
        let sorted = quotas
            .map { (accountKey: $0.key, email: $0.value.accountDisplayName ?? $0.key, data: $0.value) }
            .sorted { $0.email < $1.email }

        guard provider == .antigravity else { return sorted }
        return AccountSorting.prioritizingActive(sorted) { isActiveInIDE($0.email) }
    }

    // MARK: - Header Item
    
    private func buildHeaderItem() -> NSMenuItem {
        // 读取发生在真实 SwiftUI body，刷新开始／完成能更新原标题项。
        viewItem(for: MenuLiveContent { MenuHeaderView(isLoading: self.viewModel.isLoadingQuotas) },
                 resizesToFitContent: true)
    }

    // MARK: - Network Info Item (Proxy + Tunnel combined)

    private func buildNetworkInfoItem() -> NSMenuItem {
        let proxyManager = viewModel.proxyManager
        let networkView = MenuNetworkInfoView(
            // 原生菜单只创建一次承载视图；状态必须在 SwiftUI body 中读取，
            // 才能订阅 Observable 的变化，而不是一直显示打开菜单时的布尔快照。
            proxyState: {
                MenuProxyState(port: proxyManager.port, isRunning: proxyManager.proxyStatus.running,
                               isStarting: proxyManager.isStarting, isStopping: proxyManager.isStopping)
            },
            onProxyToggle: { [weak viewModel] in
                Task { await viewModel?.toggleProxy() }
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
        return viewItem(for: networkView, resizesToFitContent: true)
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
               let current = self.viewModel.providerQuotas[provider]?[accountKey] {
                let currentEmail = current.accountDisplayName ?? email
                MenuAccountCardView(
                    accountKey: accountKey, email: currentEmail, data: current, provider: provider,
                    subscriptionInfo: self.viewModel.subscriptionInfos[provider]?[accountKey],
                    isActiveInIDE: provider == .antigravity && self.viewModel.isAntigravityAccountActive(email: currentEmail),
                    // 回调始终保留；活动徽章由当前视图决定，IDE 切换后仍可切回另一账号。
                    onUseAccount: provider == .antigravity ? { [weak viewModel = self.viewModel] in
                        Self.showSwitchConfirmation(email: currentEmail, viewModel: viewModel)
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

    /// 所有提供商采用同一明细入口；金额／次数／状态及未知额度沿用原 ModelQuota 语义。
    /// 一个动态承载项容纳额度桶变化，避免刷新时增删 AppKit 正在跟踪的子菜单项。
    private func buildAccountDetailSubmenu(accountKey: String, email: String, provider: AIProvider) -> NSMenu {
        // 本轮原生项固定来源世代；切模式后保持项身份，但不能展示新来源的同名额度，
        // 也不能让实时明细与已装配的历史动作分别指向不同模式。
        let sourceMode = modeManager.currentMode.rawValue
        let sourceRevision = modeManager.revision
        let submenu = makeMenu()
        let details = MenuLiveContent {
            let current = self.modeManager.revision == sourceRevision
                ? self.viewModel.providerQuotas[provider]?[accountKey] : nil
            MenuAccountDetailView(
                email: current?.accountDisplayName ?? email,
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
        guard let viewModel = viewModel else { return }
        
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
        return [viewItem(for: actionsView)]
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
