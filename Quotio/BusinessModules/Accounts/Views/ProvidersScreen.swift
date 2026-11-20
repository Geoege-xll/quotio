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
    @State private var vertexImportSource: CPAFileTransferSource?
    @State private var selectedProvider: AIProvider?
    @State private var showProxyRequiredAlert = false
    @State private var showIDEScanSheet = false
    @State private var customProviderSheetMode: CustomProviderSheetMode?
    @State private var showWarpConnectionSheet = false
    @State private var editingWarpToken: WarpService.WarpToken?
    @State private var showGLMConnectionSheet = false
    @State private var editingGLMProvider: CustomProvider?
    @State private var showMainstreamConnectionSheet = false
    @State private var mainstreamTargetProvider: AIProvider = .deepseek
    @State private var editingMainstreamProvider: CustomProvider?
    @State private var showAddProviderPopover = false
    // 添加选择器和目标表单由同一窗口呈现，只有选择器关闭后才提交下一张 Sheet。
    @State private var pendingOfficialOpenAIAddition = false
    @State private var switchingAccount: AccountRowData?
    @State private var isResettingAllCooldowns = false
    // nil 表示“全部服务商”，此筛选状态与 OAuth 弹窗的 selectedProvider 完全独立。
    @State private var selectedAccountProvider: AIProvider?
    @State private var isDropTargeted = false
    @State private var quotaSettings = MenuBarSettingsManager.shared

    private let customProviderService = CustomProviderService.shared
    private let warpService = WarpService.shared

    // MARK: - Computed Properties

    /// 账号授权只提供原有 CPA 与本地配置入口；Factory Droid 等客户端配置仍在客户端管理。
    private var addableProviders: [AIProvider] {
        let mainstreamExtra: Set<AIProvider> = [.glm, .clinePass, .deepseek, .moonshot, .minimax]
        return AIProvider.allCases.filter {
            ![.factoryDroid, .openRouter, .amp].contains($0)
                && ($0.supportsManualAuth || mainstreamExtra.contains($0))
        }
    }

    /// 目录与权限分别传入：新会话尚未确认目录时继续展示上一份身份，所有 CPA 行保持只读。
    private var groupedAccounts: [AIProvider: [AccountRowData]] {
        AccountPageData.groupedAccounts(
            hasCurrentCPAAccountDirectory: viewModel.hasCurrentCPAAccountDirectory,
            authFiles: viewModel.authFiles,
            importedIDEAccountKeys: viewModel.importedIDEAccountKeys,
            customProviders: customProviderService.providers,
            warpTokens: warpService.tokens
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
        // 筛选摘要也按已显示的连接计算；未匹配的旧快照不能让服务商胶囊出现过低额度。
        let keys = groupedAccounts[provider, default: []].flatMap(\.quotaAccountKeys)
        let quotas = viewModel.providerQuotas[provider, default: [:]]
        return keys.compactMap { key in
            guard let quota = quotas[key] else { return nil }
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

                customProvidersSection
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
            allowsMultipleSelection: false,
            onCompletion: { result in
                let source = vertexImportSource
                vertexImportSource = nil
                guard let source, case .success(let urls) = result, let url = urls.first else { return }
                Task {
                    guard canUseCPAFileTransfer(source) else { return }
                    await viewModel.importVertexServiceAccount(url: url)
                }
            },
            onCancellation: {
                vertexImportSource = nil
            }
        )
        .onChange(of: sortedProviders) { _, providers in
            // 删除当前筛选的最后一个账号后，自动恢复全部列表，避免空筛选困住用户。
            if let selectedAccountProvider, !providers.contains(selectedAccountProvider) {
                self.selectedAccountProvider = nil
            }
        }
        .onChange(of: viewModel.hasCurrentCPAAccountDirectory) { _, canManage in
            if !canManage { switchingAccount = nil }
        }
        .alert("providers.proxyRequired.title".localized(), isPresented: $showProxyRequiredAlert) {
            Button("runtime.openRoutingCenter".localized()) {
                // 路由中心统一呈现安装或重启，并显示失败原因。
                viewModel.currentPage = .dashboard
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
                initialProviderType: mode.initialProviderType,
                isAddingOfficialOpenAI: mode.isAddingOfficialOpenAI
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
                    viewModel.prepareWarpQuotaMutation(previous: existing, replacement: updated)
                    warpService.updateToken(updated)
                } else {
                    warpService.addToken(name: name, token: token)
                }
                editingWarpToken = nil
                viewModel.syncMenuBarSelection()
                Task { await viewModel.refreshQuota(for: .warp, waitForAvailability: true) }
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
        .sheet(isPresented: $showMainstreamConnectionSheet) {
            MainstreamProviderAPIKeySheet(
                targetProvider: mainstreamTargetProvider,
                provider: editingMainstreamProvider
            ) { provider in
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
                editingMainstreamProvider = nil
                syncCustomProvidersToConfig()
                let target = mainstreamTargetProvider
                if target == .deepseek || target == .moonshot {
                    Task { await viewModel.refreshQuota(for: target, waitForAvailability: true) }
                }
            }
            .environment(viewModel)
        }
        .sheet(isPresented: $showAddProviderPopover, onDismiss: {
            guard pendingOfficialOpenAIAddition else { return }
            pendingOfficialOpenAIAddition = false
            // 等添加选择器的原生 Sheet 完全关闭，再展示官方表单。
            customProviderSheetMode = .addOfficialOpenAI
        }) {
            AddProviderPopover(
                providers: addableProviders,
                existingCounts: providerAccountCounts,
                onSelectProvider: { provider in
                    handleAddProvider(provider)
                },
                onScanIDEs: {
                    showIDEScanSheet = true
                },
                onAddOfficialOpenAI: { pendingOfficialOpenAIAddition = true },
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
                refreshAll: { await viewModel.manualRefresh() },
                refreshProvider: { await viewModel.refreshQuota(for: $0) },
                sharedRefresh: viewModel.manualAccountRefreshState,
                isRefreshingOverride: viewModel.canRefreshAccountQuotas
                    && (viewModel.isLoadingQuotas || viewModel.isLoading))
            .disabled(!viewModel.canRefreshAccountQuotas)
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
            .disabled(!viewModel.hasCurrentCPAAccountDirectory)
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

            let isOffline = !viewModel.proxyManager.proxyStatus.running
            let directoryError = viewModel.lastCPAAccountDirectoryError
            if isOffline || directoryError != nil {
                VStack(alignment: .leading, spacing: 4) {
                    Label(isOffline ? "accounts.quota.offline".localized() : "accounts.directory.unavailable".localized(),
                          systemImage: isOffline ? "bolt.slash" : "exclamationmark.triangle")
                    if let error = isOffline ? viewModel.proxyManager.lastError ?? directoryError : directoryError,
                       !error.isEmpty {
                        Text(error)
                            .foregroundStyle(.orange)
                            .lineLimit(3)
                            .help(error)
                    }
                }
                .font(.caption)
                .foregroundStyle(.secondary)
                .padding(.horizontal, 4)
                .accessibilityElement(children: .combine)
            }

            // 横幅只更新时间投影；到期后自动消失，不借 UI 时钟创建第二轮账号刷新。
            let cooldownAccounts = groupedAccounts.values.flatMap { $0 }.filter { $0.cooldowns?.isEmpty == false }
            if !cooldownAccounts.isEmpty {
                TimelineView(.periodic(from: .now, by: 1)) { timeline in
                    let count = cooldownAccounts.filter { !$0.activeCooldowns(at: timeline.date).isEmpty }.count
                    if count > 0 { coolingAlertBanner(count: count) }
                }
            }

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
                            } else if account.provider == .deepseek || account.provider == .moonshot || account.provider == .minimax {
                                handleEditMainstreamAccount(account)
                            } else if account.provider == .warp {
                                handleEditWarpAccount(account)
                            }
                        },
                        onSwitch: { account in
                            if viewModel.hasCurrentCPAAccountDirectory { switchingAccount = account }
                        },
                        onToggleDisabled: { account in Task { await toggleAccountDisabled(account) } },
                        onDownload: { account in Task { await downloadAccountAuthFile(account) } }
                    )
                }
            }
        }
    }

    @ViewBuilder
    private func coolingAlertBanner(count: Int) -> some View {
        HStack(spacing: 12) {
            ZStack {
                Circle()
                    .fill(Color.orange.opacity(colorScheme == .dark ? 0.25 : 0.15))
                    .frame(width: 30, height: 30)
                Image(systemName: "snowflake")
                    .font(.system(size: 14, weight: .bold))
                    .foregroundStyle(.orange)
            }

            VStack(alignment: .leading, spacing: 2) {
                Text(String(format: "credentials.cooldown.bannerTitle".localized(), Int64(count)))
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(.primary)
                Text("credentials.cooldown.bannerSubtitle".localized())
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Spacer(minLength: 8)

            Button {
                guard viewModel.hasCurrentCPAAccountDirectory else { return }
                Task {
                    isResettingAllCooldowns = true
                    defer { isResettingAllCooldowns = false }
                    await viewModel.resetAllCooldowns()
                }
            } label: {
                HStack(spacing: 5) {
                    if isResettingAllCooldowns {
                        ProgressView().controlSize(.small)
                    } else {
                        Image(systemName: "arrow.counterclockwise")
                            .font(.system(size: 10, weight: .bold))
                    }
                    Text("credentials.cooldown.resetAll".localized())
                        .font(.system(size: 11, weight: .semibold))
                }
            }
            .buttonStyle(.quotioPrimaryCapsule)
            .disabled(isResettingAllCooldowns || !viewModel.hasCurrentCPAAccountDirectory)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
        .background(
            RoundedRectangle(cornerRadius: QuotioTheme.Radius.md, style: .continuous)
                .fill(Color.orange.opacity(colorScheme == .dark ? 0.12 : 0.06))
        )
        .overlay(
            RoundedRectangle(cornerRadius: QuotioTheme.Radius.md, style: .continuous)
                .strokeBorder(Color.orange.opacity(0.3), lineWidth: 0.5)
        )
    }

    // MARK: - Custom Providers Section

    @ViewBuilder
    private var customProvidersSection: some View {
        // API-key providers with first-class quota tracking are shown in Your Accounts.
        let genericProviders = customProviderService.providers.filter {
            $0.type != .glmCompatibility
                && $0.type != .clinePass
                && $0.type != .deepseekCompatibility
                && $0.type != .moonshotCompatibility
                && $0.type != .minimaxCompatibility
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
        if provider == .deepseek || provider == .moonshot || provider == .minimax {
            editingMainstreamProvider = nil
            mainstreamTargetProvider = provider
            showMainstreamConnectionSheet = true
            return
        }
        if provider == .warp {
            editingWarpToken = nil
            showWarpConnectionSheet = true
            return
        }
        // CPA 授权和导入仍依赖当前管理接口；本地配置保持原管理入口。
        if !viewModel.canRefreshAccountQuotas {
            showProxyRequiredAlert = true
            return
        }

        if provider == .vertex {
            guard let source = currentCPAFileTransferSource() else {
                showProxyRequiredAlert = true
                return
            }
            vertexImportSource = source
            isImporterPresented = true
        } else {
            viewModel.cancelOAuth()
            selectedProvider = provider
        }
    }
    
    private func deleteAccount(_ account: AccountRowData) async {
        guard account.canDelete else { return }

        // 同一提供商可以同时有 CPA 文件和手动 Key。优先按行的来源处理，避免用文件 ID 查本地配置。
        if account.source == .proxy {
            if let authFile = currentCPAAuthFile(for: account) { await viewModel.deleteAuthFile(authFile) }
            return
        }

        // Cursor／Trae 删除仅影响用户先前显式导入的记录。
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

        if account.provider == .deepseek || account.provider == .moonshot || account.provider == .minimax {
            if let target = customProviderService.providers.first(where: { $0.id.uuidString == account.id }) {
                viewModel.prepareCustomProviderQuotaMutation(previous: target, replacement: nil,
                    legacyNameIsUnique: customProviderService.providers.filter {
                        $0.type == target.type && $0.name == target.name
                    }.count == 1)
                customProviderService.deleteProvider(id: target.id)
                viewModel.syncMenuBarSelection()
                syncCustomProvidersToConfig()
            }
            return
        }

        // Handle Warp accounts (stored in WarpService)
        if account.provider == .warp {
            if let token = warpService.tokens.first(where: { $0.id.uuidString == account.id }) {
                viewModel.prepareWarpQuotaMutation(previous: token, replacement: nil)
                warpService.deleteToken(id: token.id)
                viewModel.syncMenuBarSelection()
                await viewModel.refreshQuotaForProvider(.warp)
            }
            return
        }

    }

    private func toggleAccountDisabled(_ account: AccountRowData) async {
        guard let authFile = currentCPAAuthFile(for: account) else { return }
        await viewModel.toggleAuthFileDisabled(authFile)
    }

    private func currentCPAAuthFile(for account: AccountRowData) -> AuthFile? {
        // 延迟确认或原生菜单回调必须重新检查来源、当前目录和规范键，避免操作同名的另一份凭据。
        guard account.source == .proxy, viewModel.hasCurrentCPAAccountDirectory else { return nil }
        return viewModel.authFiles.first {
            $0.id == account.id && $0.providerType == account.provider && $0.menuBarAccountKey == account.menuBarAccountKey
        }
    }

    private struct CPAFileTransferSource {
        let context: QuotaViewModel.RefreshContext
        let client: ManagementAPIClient
    }

    /// 系统面板与拖放 URL 读取都可能让应用处理停机或重连。操作开始时固定会话和原客户端，
    /// 回到界面后再校验，避免让用户在旧代理会话里的选择送到新 CPA。
    private func currentCPAFileTransferSource() -> CPAFileTransferSource? {
        guard viewModel.hasCurrentCPAAccountDirectory, let client = viewModel.apiClient else { return nil }
        return CPAFileTransferSource(context: viewModel.refreshContext(), client: client)
    }

    private func canUseCPAFileTransfer(_ source: CPAFileTransferSource) -> Bool {
        viewModel.canUseRefreshSource(source.context) && viewModel.apiClient === source.client
            && viewModel.hasCurrentCPAAccountDirectory
    }

    private func downloadAccountAuthFile(_ account: AccountRowData) async {
        guard account.canDownloadAuthFile, let source = currentCPAFileTransferSource(),
              let file = currentCPAAuthFile(for: account), file.name == account.authFileName else { return }

        let filename = file.name
        // 导出接口只收文件名，因此在交给它之前必须再次确认原账号、规范键与文件名。
        func canExportOriginalFile() -> Bool {
            canUseCPAFileTransfer(source) && currentCPAAuthFile(for: account)?.name == filename
        }
        let savePanel = NSSavePanel()
        savePanel.nameFieldStringValue = filename.hasSuffix(".json") ? filename : filename + ".json"
        savePanel.allowedContentTypes = [.json]
        savePanel.canCreateDirectories = true

        guard savePanel.runModal() == .OK, let url = savePanel.url,
              canExportOriginalFile() else { return }

        do {
            try await viewModel.exportAuthFile(name: filename, to: url)
        } catch {
            guard !(error is CancellationError), canExportOriginalFile() else { return }
            viewModel.errorMessage = error.localizedDescription
        }
    }

    private func handleEditGlmAccount(_ account: AccountRowData) {
        if let glmProvider = customProviderService.providers.first(where: { $0.id.uuidString == account.id }) {
            editingGLMProvider = glmProvider
            showGLMConnectionSheet = true
        }
    }

    private func handleEditMainstreamAccount(_ account: AccountRowData) {
        if let target = customProviderService.providers.first(where: { $0.id.uuidString == account.id }) {
            editingMainstreamProvider = target
            mainstreamTargetProvider = account.provider
            showMainstreamConnectionSheet = true
        }
    }

    private func handleEditClinePassAccount(_ account: AccountRowData) {
        if let provider = customProviderService.providers.first(where: { $0.id.uuidString == account.id }) {
            customProviderSheetMode = .edit(provider)
        }
    }

    private func uploadAuthFile() {
        guard let source = currentCPAFileTransferSource() else { return }
        let openPanel = NSOpenPanel()
        openPanel.allowsMultipleSelection = true
        openPanel.allowedContentTypes = [.json]
        openPanel.canChooseDirectories = false

        if openPanel.runModal() == .OK {
            let urls = openPanel.urls
            guard !urls.isEmpty, canUseCPAFileTransfer(source) else { return }
            Task {
                guard canUseCPAFileTransfer(source) else { return }
                await viewModel.importAuthFiles(from: urls)
            }
        }
    }

    private func handleFileDrop(providers: [NSItemProvider]) -> Bool {
        guard let source = currentCPAFileTransferSource() else { return false }
        let fileProviders = providers.filter { $0.hasItemConformingToTypeIdentifier(UTType.fileURL.identifier) }
        guard !fileProviders.isEmpty else { return false }
        Task {
            guard canUseCPAFileTransfer(source) else { return }
            var droppedURLs: [URL] = []
            for itemProvider in fileProviders {
                let url = await loadURL(from: itemProvider)
                guard canUseCPAFileTransfer(source) else { return }
                if let url, url.pathExtension.lowercased() == "json" {
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

    private func syncCustomProvidersToConfig() {
        // 显式配置变更就是菜单目录变化，不能等离线额度刷新成功后才发布。
        viewModel.syncMenuBarSelection()
        // 服务运行时使用 CPA 8 的局部配置接口；停止时由下一次启动统一同步。
        Task { @MainActor in
            let source = viewModel.refreshContext()
            do {
                try await viewModel.proxyManager.syncCustomProvidersToConfig()
                guard viewModel.proxyManager.proxyStatus.running else { return }
                // API Key 连接的启停／编辑也会改变 CPA 暴露的模型；必须等 v8 同步成功后再读目录。
                // 复用本任务及两个目录原宿主，旧代理／模式响应不能废弃新目录；停止时不额外请求。
                let refresh = viewModel.invalidateModelsAfterCPAAccountChange(source: source)
                await viewModel.refreshModelsAfterCPAAccountChange(refresh)
            } catch {
                guard viewModel.canUseRefreshSource(source) else { return }
                viewModel.errorMessage = error.localizedDescription
            }
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

// MARK: - Custom Provider Sheet Mode

enum CustomProviderSheetMode: Identifiable {
    case add(CustomProviderType)
    case addOfficialOpenAI
    case edit(CustomProvider)

    var id: String {
        switch self {
        case .add(let type):
            return "add-\(type.rawValue)"
        case .addOfficialOpenAI:
            return "add-official-openai"
        case .edit(let provider):
            return provider.id.uuidString
        }
    }

    var provider: CustomProvider? {
        switch self {
        case .add, .addOfficialOpenAI:
            return nil
        case .edit(let provider):
            return provider
        }
    }

    var initialProviderType: CustomProviderType {
        switch self {
        case .add(let type):
            return type
        case .addOfficialOpenAI:
            return .openaiCompatibility
        case .edit(let provider):
            return provider.type
        }
    }

    var isAddingOfficialOpenAI: Bool {
        if case .addOfficialOpenAI = self { return true }
        return false
    }
}
