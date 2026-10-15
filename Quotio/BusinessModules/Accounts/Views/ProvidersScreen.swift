//
//  ProvidersScreen.swift
//  Quotio
//
//  账号融合页：直接在同一账号下呈现管理操作与完整额度。
//  保留 ProvidersScreen 类型以兼容既有入口；服务商筛选使用统一分段控件。
//  原有授权、导入、扫描和专属配置弹窗继续由本页宿主持有。
//

import SwiftUI
import AppKit
import UniformTypeIdentifiers

// 账号页继续持有原列表、表单和弹窗选择；共享 OAuthSheet 已按实际双业务使用方归位。
// 原调用与回调不变，授权会话继续委托同一个 QuotaViewModel 与协调器。

struct ProvidersScreen: View {
    @Environment(QuotaViewModel.self) private var viewModel
    @Environment(\.colorScheme) private var colorScheme
    @State private var isImporterPresented = false
    @State private var selectedProvider: AIProvider?
    @State private var showProxyRequiredAlert = false
    @State private var showIDEScanSheet = false
    @State private var customProviderSheetMode: CustomProviderSheetMode?
    @State private var showWarpConnectionSheet = false
    @State private var editingWarpToken: WarpService.WarpToken?
    @State private var showGLMConnectionSheet = false
    @State private var editingGLMProvider: CustomProvider?
    @State private var monitorAPIKeyProvider: AIProvider?
    @State private var editingMonitorAPIKeyAccount: MonitorAccount?
    @State private var showAddProviderPopover = false
    @State private var switchingAccount: AccountRowData?
    // nil 表示“全部服务商”，此筛选状态与 OAuth 弹窗的 selectedProvider 完全独立。
    @State private var selectedAccountProvider: AIProvider?
    @State private var isDropTargeted = false
    @State private var quotaSettings = MenuBarSettingsManager.shared
    @State private var modeManager = OperatingModeManager.shared

    private let customProviderService = CustomProviderService.shared
    private let warpService = WarpService.shared
    
    // MARK: - Computed Properties
    
    /// Providers that can be added manually
    private var addableProviders: [AIProvider] {
        if modeManager.isLocalProxyMode {
            return AIProvider.allCases.filter {
                ![.factoryDroid, .openRouter, .amp].contains($0) && ($0.supportsManualAuth(in: .localProxy) || $0 == .clinePass)
            }
        } else {
            return AIProvider.allCases.filter {
                $0.supportsQuotaOnlyMode
                    && ($0.supportsManualAuth(in: .monitor) || $0 == .glm || $0 == .clinePass)
                    && ($0 != .amp || modeManager.isMonitorMode)
            }
        }
    }
    
    /// 统一连接目录与额度缓存；完整来源规则位于可离线测试的 AccountPageData。
    private var groupedAccounts: [AIProvider: [AccountRowData]] {
        AccountPageData.groupedAccounts(
            mode: modeManager.currentMode,
            proxyRunning: viewModel.proxyManager.proxyStatus.running,
            authFiles: viewModel.authFiles,
            directAuthFiles: viewModel.directAuthFiles,
            monitorAccounts: viewModel.monitorAccounts,
            quotas: viewModel.providerQuotas,
            customProviders: customProviderService.providers,
            warpTokens: warpService.tokens,
            monitorStatus: { account in
                let state = viewModel.monitorStatus(for: account)
                return (state.status, state.message)
            }
        )
    }

    /// Sorted providers for consistent display order
    private var sortedProviders: [AIProvider] {
        groupedAccounts.keys.sorted { $0.displayName < $1.displayName }
    }
    
    /// Total account count across all providers
    private var totalAccountCount: Int {
        groupedAccounts.values.reduce(0) { $0 + $1.count }
    }

    /// Account count per provider (for AddProviderPopover badge display)
    private var providerAccountCounts: [AIProvider: Int] {
        groupedAccounts.mapValues { $0.count }
    }

    private var filteredProviders: [AIProvider] {
        sortedProviders.filter { selectedAccountProvider == nil || $0 == selectedAccountProvider }
    }

    /// 所有选项使用项目定义的分段控件；即使只有一个服务商，也提供“全部”范围。
    private var providerFilter: some View {
        AccountProviderFilter(
            providers: sortedProviders,
            accountCounts: providerAccountCounts,
            lowestPercentages: sortedProviders.reduce(into: [:]) { result, provider in
                result[provider] = lowestQuotaPercent(for: provider)
            },
            selection: $selectedAccountProvider
        )
    }

    private func lowestQuotaPercent(for provider: AIProvider) -> Double? {
        viewModel.providerQuotas[provider]?.values.compactMap { quota in
            let value = quotaSettings.quotaSummaryPercentage(for: provider, models: quota.models)
            return value >= 0 && value.isFinite ? value : nil
        }.min()
    }

    // MARK: - Body

    var body: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 20) {
                // 添加账号集中在工具栏；移除顶部重复的快速添加摘要，给账号内容更多空间。

                // 一个账号同时呈现连接操作与完整额度，不再嵌套第二个额度页面或 Tab。
                providerFilter
                accountsSection

                // Section 2: Custom Providers (Local Proxy Mode only)
                if modeManager.isLocalProxyMode {
                    customProvidersSection
                }
            }
            .padding(20)
        }
        .quotioPage()
        .overlay {
            if isDropTargeted {
                RoundedRectangle(cornerRadius: 12)
                    .strokeBorder(Color.accentColor, style: StrokeStyle(lineWidth: 2, dash: [8, 4]))
                    .background(Color.accentColor.opacity(0.06).cornerRadius(12))
                    .padding(8)
                    .allowsHitTesting(false)
            }
        }
        .onDrop(of: [.fileURL], isTargeted: $isDropTargeted) { providers in
            handleFileDrop(providers: providers)
        }
        .navigationTitle("nav.accounts".localized())
        .toolbar {
            toolbarContent
        }
        .sheet(item: $selectedProvider) { provider in
            OAuthSheet(provider: provider) {
                selectedProvider = nil
                viewModel.cancelOAuth()
            }
            .environment(viewModel)
        }
        .fileImporter(
            isPresented: $isImporterPresented,
            allowedContentTypes: [.json],
            allowsMultipleSelection: false
        ) { result in
            if case .success(let urls) = result, let url = urls.first {
                Task { await viewModel.importVertexServiceAccount(url: url) }
            }
            // Failure case is silently ignored - user can retry via UI
        }
        .task {
            await viewModel.loadDirectAuthFiles()
        }
        .onChange(of: sortedProviders) { _, providers in
            // 删除最后一个被筛选的账号或切换运行模式后，自动恢复全部列表，避免空筛选困住用户。
            if let selectedAccountProvider, !providers.contains(selectedAccountProvider) {
                self.selectedAccountProvider = nil
            }
        }
        .alert("providers.proxyRequired.title".localized(), isPresented: $showProxyRequiredAlert) {
            Button("action.startProxy".localized()) {
                Task { await viewModel.startProxy() }
            }
            Button("action.cancel".localized(), role: .cancel) {}
        } message: {
            Text("providers.proxyRequired.message".localized())
        }
        .sheet(isPresented: $showIDEScanSheet) {
            IDEScanSheet {}
            .environment(viewModel)
        }
        .sheet(item: $customProviderSheetMode) { mode in
            CustomProviderSheet(
                provider: mode.provider,
                initialProviderType: mode.initialProviderType
            ) { provider in
                // Check if provider already exists by ID to determine if we're updating or adding
                let previous = customProviderService.providers.first { $0.id == provider.id }
                viewModel.prepareCustomProviderQuotaMutation(previous: previous, replacement: provider,
                    legacyNameIsUnique: previous.map { old in
                        customProviderService.providers.filter { $0.type == old.type && $0.name == old.name }.count == 1
                    } ?? false)
                if previous != nil {
                    customProviderService.updateProvider(provider)
                } else {
                    customProviderService.addProvider(provider)
                }
                syncCustomProvidersToConfig()
                if provider.type == .clinePass {
                    Task { await viewModel.refreshQuota(for: .clinePass, waitForAvailability: true) }
                }
            }
        }
        .sheet(isPresented: $showWarpConnectionSheet) {
            WarpConnectionSheet(token: editingWarpToken) { name, token in
                if let existing = editingWarpToken {
                    var updated = existing
                    updated.name = name
                    updated.token = token
                    warpService.updateToken(updated)
                } else {
                    warpService.addToken(name: name, token: token)
                }
                editingWarpToken = nil
                Task { await viewModel.refreshAutoDetectedProviders() }
            }
        }
        .sheet(isPresented: $showGLMConnectionSheet) {
            GLMAPIKeySheet(provider: editingGLMProvider) { provider in
                let previous = customProviderService.providers.first { $0.id == provider.id }
                viewModel.prepareCustomProviderQuotaMutation(previous: previous, replacement: provider,
                    legacyNameIsUnique: previous.map { old in
                        customProviderService.providers.filter { $0.type == old.type && $0.name == old.name }.count == 1
                    } ?? false)
                if previous != nil {
                    customProviderService.updateProvider(provider)
                } else {
                    customProviderService.addProvider(provider)
                }
                editingGLMProvider = nil
                syncCustomProvidersToConfig()
                Task { await viewModel.refreshQuota(for: .glm, waitForAvailability: true) }
            }
            .environment(viewModel)
        }
        .sheet(item: $monitorAPIKeyProvider) { provider in
            MonitorAPIKeyConnectionSheet(provider: provider, account: editingMonitorAPIKeyAccount) { label, apiKey in
                if provider == .factoryDroid {
                    try await viewModel.saveFactoryDroidAccount(
                        label: label,
                        apiKey: apiKey,
                        existingAccountID: editingMonitorAPIKeyAccount?.id
                    )
                } else if provider == .amp {
                    try await viewModel.saveAmpAccount(
                        label: label,
                        apiKey: apiKey,
                        existingAccountID: editingMonitorAPIKeyAccount?.id
                    )
                } else {
                    try await viewModel.saveOpenRouterAccount(
                        label: label,
                        apiKey: apiKey,
                        existingAccountID: editingMonitorAPIKeyAccount?.id
                    )
                }
                editingMonitorAPIKeyAccount = nil
            }
        }
        .sheet(isPresented: $showAddProviderPopover) {
            AddProviderPopover(
                providers: addableProviders,
                existingCounts: providerAccountCounts,
                onSelectProvider: { provider in
                    handleAddProvider(provider)
                },
                onScanIDEs: {
                    showIDEScanSheet = true
                },
                onAddCustomProvider: {
                    customProviderSheetMode = .add(.openaiCompatibility)
                },
                onDismiss: {
                    showAddProviderPopover = false
                }
            )
        }
        .sheet(item: $switchingAccount) { account in
            SwitchAccountSheet(
                accountEmail: account.displayName,
                onDismiss: {
                    switchingAccount = nil
                }
            )
            .environment(viewModel)
        }
    }
    
    /// 保留管理目录、全部额度与 Grok／Devin 补充刷新。等待由 ViewModel 在实际
    /// 获取批次槽位时完成，目录读取期间出现新的后台批次也不会丢失用户操作。
    private func refreshAllAccounts() async {
        await viewModel.manualRefresh()
    }

    // MARK: - Toolbar
    
    @ToolbarContentBuilder
    private var toolbarContent: some ToolbarContent {
        ToolbarItem(placement: .automatic) {
            Menu {
                // 沿用现有偏好键，因此旧展示样式、已用／剩余设置与菜单栏保持一致。
                Picker(selection: $quotaSettings.quotaDisplayStyle) {
                    ForEach(QuotaDisplayStyle.allCases) { style in
                        Label(style.localizationKey.localized(), systemImage: style.iconName).tag(style)
                    }
                } label: { Text("settings.quota.displayStyle".localized()) }
                .pickerStyle(.inline)
                Divider()
                Picker(selection: $quotaSettings.quotaDisplayMode) {
                    ForEach(QuotaDisplayMode.allCases) { mode in
                        Text(mode.localizationKey.localized()).tag(mode)
                    }
                } label: { Text("display_mode".localized()) }
                .pickerStyle(.inline)
            } label: { Image(systemName: "slider.horizontal.3") }
            .help("settings.quota.displayStyle".localized())
            .accessibilityLabel("settings.quota.displayStyle".localized())
        }

        ToolbarItem(placement: .automatic) {
            // 全量刷新与按服务商刷新共用一个原生菜单；当前筛选仍限制服务商列表。
            AccountRefreshMenu(providers: filteredProviders,
                unavailableProviders: Set(filteredProviders.filter {
                    viewModel.isRefreshing(provider: $0) || !viewModel.supportsScopedRefresh(for: $0)
                }),
                refreshAll: { await refreshAllAccounts() },
                refreshProvider: { await viewModel.refreshQuota(for: $0) },
                sharedRefresh: viewModel.manualAccountRefreshState,
                isRefreshingOverride: viewModel.isLoadingQuotas || viewModel.isLoading)
        }

        ToolbarItem(placement: .primaryAction) {
            Button {
                showAddProviderPopover = true
            } label: {
                Image(systemName: "plus")
            }
            .help("providers.addAccount".localized())
        }
        

        ToolbarItem(placement: .automatic) {
            Button {
                uploadAuthFile()
            } label: {
                Image(systemName: "arrow.up.circle")
            }
            .help("action.upload".localized())
        }
    }
    
    // MARK: - Accounts Section

    @ViewBuilder
    private var accountsSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            // Section Header
            HStack {
                Label("providers.yourAccounts".localized(), systemImage: "person.2.badge.key")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(.secondary)

                if totalAccountCount > 0 {
                    Spacer()
                    Text("\(totalAccountCount)")
                        .font(.caption2.bold().monospacedDigit())
                        .padding(.horizontal, 7)
                        .padding(.vertical, 2.5)
                        .background(QuotioTheme.Colors.cardInset(for: colorScheme), in: Capsule())
                        .foregroundStyle(.secondary)
                        .overlay(
                            Capsule()
                                .strokeBorder(QuotioTheme.Colors.sidebarBorder(for: colorScheme), lineWidth: 0.5)
                        )
                }
            }
            .padding(.horizontal, 4)

            if groupedAccounts.isEmpty {
                // Empty state
                AccountsEmptyState(
                    onScanIDEs: {
                        showIDEScanSheet = true
                    },
                    onAddProvider: {
                        showAddProviderPopover = true
                    }
                )
            } else {
                // Grouped accounts by provider as collapsible cards
                VStack(spacing: 10) {
                    AccountProviderGroups(
                        groups: groupedAccounts,
                        selection: selectedAccountProvider,
                        quotaDisplayStyle: quotaSettings.quotaDisplayStyle,
                        onDelete: { account in Task { await deleteAccount(account) } },
                        onEdit: { account in
                            if account.provider == .glm {
                                handleEditGlmAccount(account)
                            } else if account.provider == .clinePass {
                                handleEditClinePassAccount(account)
                            } else if account.provider == .warp {
                                handleEditWarpAccount(account)
                            } else if [.factoryDroid, .openRouter, .amp].contains(account.provider) {
                                handleEditMonitorAPIKeyAccount(account)
                            }
                        },
                        onSwitch: { switchingAccount = $0 },
                        onToggleDisabled: { account in Task { await toggleAccountDisabled(account) } },
                        onDownload: { account in Task { await downloadAccountAuthFile(account) } }
                    )
                }

                MenuBarHintView()
                    .padding(.top, 4)
                    .padding(.horizontal, 4)
            }
        }
    }

    // MARK: - Custom Providers Section

    @ViewBuilder
    private var customProvidersSection: some View {
        // API-key providers with first-class quota tracking are shown in Your Accounts.
        let genericProviders = customProviderService.providers.filter {
            $0.type != .glmCompatibility && $0.type != .clinePass
        }

        VStack(alignment: .leading, spacing: 12) {
            // Section Header
            HStack {
                Label("customProviders.title".localized(), systemImage: "puzzlepiece.extension.fill")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(.secondary)

                if !genericProviders.isEmpty {
                    Spacer()
                    Text("\(genericProviders.count)")
                        .font(.caption2.bold().monospacedDigit())
                        .padding(.horizontal, 7)
                        .padding(.vertical, 2.5)
                        .background(QuotioTheme.Colors.cardInset(for: colorScheme), in: Capsule())
                        .foregroundStyle(.secondary)
                        .overlay(
                            Capsule()
                                .strokeBorder(QuotioTheme.Colors.sidebarBorder(for: colorScheme), lineWidth: 0.5)
                        )
                }
            }
            .padding(.horizontal, 4)

            if !genericProviders.isEmpty {
                VStack(spacing: 8) {
                    ForEach(genericProviders) { provider in
                        CustomProviderRow(
                            provider: provider,
                            onEdit: {
                                customProviderSheetMode = .edit(provider)
                            },
                            onDelete: {
                                customProviderService.deleteProvider(id: provider.id)
                                syncCustomProvidersToConfig()
                            },
                            onToggle: {
                                customProviderService.toggleProvider(id: provider.id)
                                syncCustomProvidersToConfig()
                            }
                        )
                    }
                }

                Text("customProviders.footer".localized())
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
                    .padding(.horizontal, 4)
            }
        }
    }
    
    // MARK: - Helper Functions

    private func handleAddProvider(_ provider: AIProvider) {
        if provider == .clinePass {
            customProviderSheetMode = .add(.clinePass)
            return
        }
        if provider == .glm {
            editingGLMProvider = nil
            showGLMConnectionSheet = true
            return
        }
        if [.factoryDroid, .openRouter, .amp].contains(provider) {
            editingMonitorAPIKeyAccount = nil
            monitorAPIKeyProvider = provider
            return
        }

        // In Local Proxy Mode, require proxy to be running for OAuth
        if modeManager.isLocalProxyMode && !viewModel.proxyManager.proxyStatus.running {
            showProxyRequiredAlert = true
            return
        }

        if provider == .vertex {
            isImporterPresented = true
        } else if provider == .warp {
            editingWarpToken = nil
            showWarpConnectionSheet = true
        } else {
            viewModel.cancelOAuth()
            selectedProvider = provider
        }
    }
    
    private func deleteAccount(_ account: AccountRowData) async {
        // Only proxy accounts can be deleted via API
        guard account.canDelete else { return }

        if modeManager.isMonitorMode, case .monitor = account.source {
            await viewModel.deleteMonitorAccount(accountID: account.id)
            return
        }

        // Handle auto-detected IDE accounts (Cursor, Trae) imported via "Scan for IDEs"
        if account.source == .autoDetected {
            await viewModel.deleteAutoDetectedAccount(
                provider: account.provider,
                accountKey: account.menuBarAccountKey
            )
            return
        }

        // Handle GLM accounts (stored in CustomProviderService)
        if account.provider == .glm {
            // GLM accounts are stored as custom providers
            // Find the GLM provider by ID and delete it
            if let glmProvider = customProviderService.providers.first(where: { $0.id.uuidString == account.id }) {
                viewModel.prepareCustomProviderQuotaMutation(previous: glmProvider, replacement: nil,
                    legacyNameIsUnique: customProviderService.providers.filter {
                        $0.type == glmProvider.type && $0.name == glmProvider.name
                    }.count == 1)
                customProviderService.deleteProvider(id: glmProvider.id)
                viewModel.syncMenuBarSelection()
                syncCustomProvidersToConfig()
            }
            return
        }

        if account.provider == .clinePass {
            if let provider = customProviderService.providers.first(where: { $0.id.uuidString == account.id }) {
                viewModel.prepareCustomProviderQuotaMutation(previous: provider, replacement: nil,
                    legacyNameIsUnique: customProviderService.providers.filter {
                        $0.type == provider.type && $0.name == provider.name
                    }.count == 1)
                customProviderService.deleteProvider(id: provider.id)
                viewModel.syncMenuBarSelection()
                syncCustomProvidersToConfig()
                await viewModel.refreshQuota(for: .clinePass, waitForAvailability: true)
            }
            return
        }
        
        // Handle Warp accounts (stored in WarpService)
        if account.provider == .warp {
            if let uuid = UUID(uuidString: account.id) {
                warpService.deleteToken(id: uuid)
                await viewModel.refreshQuotaForProvider(.warp)
            }
            return
        }

        // Find the original AuthFile to delete
        if let authFile = viewModel.authFiles.first(where: { $0.id == account.id }) {
            await viewModel.deleteAuthFile(authFile)
        }
    }

    private func toggleAccountDisabled(_ account: AccountRowData) async {
        if modeManager.isMonitorMode, case .monitor = account.source {
            await viewModel.setMonitorAccountDisabled(!account.isDisabled, accountID: account.id)
            return
        }

        guard account.source == .proxy else { return }

        // Find the original AuthFile to toggle
        if let authFile = viewModel.authFiles.first(where: { $0.id == account.id }) {
            await viewModel.toggleAuthFileDisabled(authFile)
        }
    }

    private func downloadAccountAuthFile(_ account: AccountRowData) async {
        guard let filename = account.authFileName else { return }

        let savePanel = NSSavePanel()
        savePanel.nameFieldStringValue = filename.hasSuffix(".json") ? filename : filename + ".json"
        savePanel.allowedContentTypes = [.json]
        savePanel.canCreateDirectories = true

        guard savePanel.runModal() == .OK, let url = savePanel.url else { return }

        do {
            try await viewModel.exportAuthFile(name: filename, to: url)
        } catch {
            viewModel.errorMessage = error.localizedDescription
        }
    }

    private func handleEditGlmAccount(_ account: AccountRowData) {
        if let glmProvider = customProviderService.providers.first(where: { $0.id.uuidString == account.id }) {
            editingGLMProvider = glmProvider
            showGLMConnectionSheet = true
        }
    }

    private func handleEditClinePassAccount(_ account: AccountRowData) {
        if let provider = customProviderService.providers.first(where: { $0.id.uuidString == account.id }) {
            customProviderSheetMode = .edit(provider)
        }
    }

    private func uploadAuthFile() {
        let openPanel = NSOpenPanel()
        openPanel.allowsMultipleSelection = true
        openPanel.allowedContentTypes = [.json]
        openPanel.canChooseDirectories = false

        if openPanel.runModal() == .OK {
            let urls = openPanel.urls
            guard !urls.isEmpty else { return }
            Task {
                await viewModel.importAuthFiles(from: urls)
            }
        }
    }

    private func handleFileDrop(providers: [NSItemProvider]) -> Bool {
        let fileProviders = providers.filter { $0.hasItemConformingToTypeIdentifier(UTType.fileURL.identifier) }
        guard !fileProviders.isEmpty else { return false }
        Task {
            var droppedURLs: [URL] = []
            for itemProvider in fileProviders {
                if let url = await loadURL(from: itemProvider), url.pathExtension.lowercased() == "json" {
                    droppedURLs.append(url)
                }
            }
            if !droppedURLs.isEmpty {
                await viewModel.importAuthFiles(from: droppedURLs)
            }
        }
        return true
    }

    private func loadURL(from itemProvider: NSItemProvider) async -> URL? {
        await withCheckedContinuation { continuation in
            if itemProvider.canLoadObject(ofClass: URL.self) {
                _ = itemProvider.loadObject(ofClass: URL.self) { url, _ in
                    continuation.resume(returning: url)
                }
            } else {
                itemProvider.loadItem(forTypeIdentifier: UTType.fileURL.identifier, options: nil) { item, _ in
                    if let data = item as? Data, let url = URL(dataRepresentation: data, relativeTo: nil) {
                        continuation.resume(returning: url)
                    } else if let url = item as? URL {
                        continuation.resume(returning: url)
                    } else {
                        continuation.resume(returning: nil)
                    }
                }
            }
        }
    }

    private func handleEditWarpAccount(_ account: AccountRowData) {
        // Find the Warp token by ID and open edit sheet
        if let token = warpService.tokens.first(where: { $0.id.uuidString == account.id }) {
            editingWarpToken = token
            showWarpConnectionSheet = true
        }
    }

    private func handleEditMonitorAPIKeyAccount(_ account: AccountRowData) {
        guard let monitorAccount = viewModel.monitorAccounts.first(where: { $0.id == account.id }) else { return }
        editingMonitorAPIKeyAccount = monitorAccount
        monitorAPIKeyProvider = monitorAccount.provider
    }

    private func syncCustomProvidersToConfig() {
        // 服务运行时使用 CPA 8 的局部配置接口；停止时由下一次启动统一同步。
        Task { @MainActor in
            do { try await viewModel.proxyManager.syncCustomProvidersToConfig() }
            catch { viewModel.errorMessage = error.localizedDescription }
        }
    }
}

// MARK: - Custom Provider Row

struct CustomProviderRow: View {
    @Environment(\.colorScheme) private var colorScheme
    let provider: CustomProvider
    let onEdit: () -> Void
    let onDelete: () -> Void
    let onToggle: () -> Void

    @State private var showDeleteConfirmation = false
    @State private var isHovered = false

    var body: some View {
        HStack(spacing: 12) {
            // Provider type icon
            ZStack {
                RoundedRectangle(cornerRadius: QuotioTheme.Radius.sm, style: .continuous)
                    .fill(provider.type.color.opacity(0.12))
                    .frame(width: 32, height: 32)

                Image(provider.type.providerIconName)
                    .resizable()
                    .aspectRatio(contentMode: .fit)
                    .frame(width: 18, height: 18)
            }

            // Provider info
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    Text(provider.name)
                        .font(.system(size: 13, weight: .medium))

                    if !provider.isEnabled {
                        Text("customProviders.disabled".localized())
                            .font(.caption2)
                            .padding(.horizontal, 6)
                            .padding(.vertical, 2)
                            .background(Color.secondary.opacity(0.2))
                            .foregroundStyle(.secondary)
                            .clipShape(Capsule())
                    }
                }

                HStack(spacing: 6) {
                    Text(provider.type.localizedDisplayName)
                        .font(.caption)
                        .foregroundStyle(.secondary)

                    Text("•")
                        .font(.caption)
                        .foregroundStyle(.tertiary)

                    let keyCount = provider.apiKeys.count
                    Text("\(keyCount) \(keyCount == 1 ? "customProviders.key".localized() : "customProviders.keys".localized())")
                        .font(.caption)
                        .foregroundStyle(.tertiary)
                }
            }

            Spacer(minLength: 8)

            // 操作按钮组：遵循“外方内圆”与圆形胶囊按钮规范，直接提供启用/停用、编辑与删除按钮
            HStack(spacing: 8) {
                // 启用 / 停用切换按钮
                let toggleTitle = provider.isEnabled ? "customProviders.disable".localized() : "customProviders.enable".localized()
                QuotioCircularIconButton(
                    systemImage: provider.isEnabled ? "checkmark.circle.fill" : "circle",
                    tint: provider.isEnabled ? .green : .secondary,
                    backgroundTint: provider.isEnabled ? .green : nil,
                    tooltip: toggleTitle
                ) {
                    onToggle()
                }
                .accessibilityLabel(toggleTitle)
                .accessibilityIdentifier("customProviders.toggle.\(provider.id.uuidString)")

                // 编辑按钮
                QuotioCircularIconButton(
                    systemImage: "pencil",
                    tint: .blue,
                    backgroundTint: .blue,
                    tooltip: "action.edit".localized()
                ) {
                    onEdit()
                }
                .accessibilityLabel("action.edit".localized())
                .accessibilityIdentifier("customProviders.edit.\(provider.id.uuidString)")

                // 删除按钮（点击弹出二次确认对话框，防误触）
                QuotioCircularIconButton(
                    systemImage: "trash",
                    tint: .red,
                    backgroundTint: .red,
                    tooltip: "action.delete".localized()
                ) {
                    showDeleteConfirmation = true
                }
                .accessibilityLabel("action.delete".localized())
                .accessibilityIdentifier("customProviders.delete.\(provider.id.uuidString)")
            }
            .fixedSize(horizontal: true, vertical: false)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
        .background(
            isHovered
                ? QuotioTheme.Colors.cardElevated(for: colorScheme)
                : QuotioTheme.Colors.cardBackground(for: colorScheme),
            in: RoundedRectangle(cornerRadius: QuotioTheme.Radius.md, style: .continuous)
        )
        .overlay(
            RoundedRectangle(cornerRadius: QuotioTheme.Radius.md, style: .continuous)
                .strokeBorder(QuotioTheme.Colors.sidebarBorder(for: colorScheme).opacity(isHovered ? 0.8 : 0.4), lineWidth: 0.5)
        )
        .onHover { hovering in
            withAnimation(.easeInOut(duration: 0.12)) {
                isHovered = hovering
            }
        }
        .contentShape(Rectangle())
        .contextMenu {
            Button {
                onEdit()
            } label: {
                Label("action.edit".localized(), systemImage: "pencil")
            }
            
            Button {
                onToggle()
            } label: {
                Label(provider.isEnabled ? "customProviders.disable".localized() : "customProviders.enable".localized(), systemImage: provider.isEnabled ? "xmark.circle" : "checkmark.circle")
            }
            
            Divider()
            
            Button(role: .destructive) {
                showDeleteConfirmation = true
            } label: {
                Label("action.delete".localized(), systemImage: "trash")
            }
        }
        .confirmationDialog(
            "customProviders.deleteConfirm".localized(),
            isPresented: $showDeleteConfirmation,
            titleVisibility: .visible
        ) {
            Button("action.delete".localized(), role: .destructive) {
                onDelete()
            }
            Button("action.cancel".localized(), role: .cancel) {}
        } message: {
            Text("customProviders.deleteMessage".localized())
        }
    }
}

// MARK: - Menu Bar Badge Component

struct MenuBarBadge: View {
    @Environment(\.colorScheme) private var colorScheme
    let isSelected: Bool
    let onTap: () -> Void

    @State private var isHovered = false

    var body: some View {
        Button(action: onTap) {
            ZStack {
                Circle()
                    .fill(
                        isSelected
                            ? Color.blue.opacity(colorScheme == .dark ? 0.22 : 0.12)
                            : (isHovered ? QuotioTheme.Colors.cardElevated(for: colorScheme) : QuotioTheme.Colors.cardInset(for: colorScheme))
                    )

                if isSelected {
                    Circle()
                        .strokeBorder(Color.blue.opacity(0.35), lineWidth: 0.5)
                } else {
                    Circle()
                        .strokeBorder(QuotioTheme.Colors.sidebarBorder(for: colorScheme).opacity(isHovered ? 0.8 : 0.4), lineWidth: 0.5)
                }

                Image(systemName: isSelected ? "chart.bar.fill" : "chart.bar")
                    .font(.system(size: 11.5, weight: isSelected ? .semibold : .medium))
                    .foregroundStyle(isSelected ? Color.blue : Color.secondary)
            }
            .frame(width: 26, height: 26)
            .contentShape(Circle())
        }
        .buttonStyle(TactileCircularButtonStyle())
        .onHover { hovering in
            withAnimation(.easeInOut(duration: 0.12)) {
                isHovered = hovering
            }
        }
        .nativeTooltip(isSelected ? "menubar.hideFromMenuBar".localized() : "menubar.showOnMenuBar".localized())
        .help(isSelected ? "menubar.hideFromMenuBar".localized() : "menubar.showOnMenuBar".localized())
    }
}

// MARK: - Menu Bar Hint View

struct MenuBarHintView: View {
    var body: some View {
        HStack(spacing: 6) {
            Image(systemName: "chart.bar.fill")
                .foregroundStyle(.blue)
                .font(.caption2)
            Text("menubar.hint".localized())
                .font(.caption2)
                .foregroundStyle(.secondary)
        }
    }
}



// MARK: - Custom Provider Sheet Mode

enum CustomProviderSheetMode: Identifiable {
    case add(CustomProviderType)
    case edit(CustomProvider)

    var id: String {
        switch self {
        case .add(let type):
            return "add-\(type.rawValue)"
        case .edit(let provider):
            return provider.id.uuidString
        }
    }

    var provider: CustomProvider? {
        switch self {
        case .add:
            return nil
        case .edit(let provider):
            return provider
        }
    }

    var initialProviderType: CustomProviderType {
        switch self {
        case .add(let type):
            return type
        case .edit(let provider):
            return provider.type
        }
    }
}
