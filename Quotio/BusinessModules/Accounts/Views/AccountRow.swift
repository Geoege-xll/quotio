//
//  AccountRow.swift
//  Quotio
//
//  Unified account row component for ProvidersScreen.
//  Replaces: AuthFileRow, DirectAuthFileRow, AutoDetectedAccountRow
//

import SwiftUI

/// Represents the source/type of an account for display purposes
enum AccountSource: Equatable {
    case proxy           // From proxy API (AuthFile)
    case direct          // From disk auth files (DirectAuthFile)
    case autoDetected    // Auto-detected from IDE (Cursor, Trae)
    case monitor(MonitorAccountSource)
    // 只有额度快照、尚未匹配到连接的条目。不能伪装成有效认证或赋予删除凭据权限。
    case quotaCache
    
    var displayName: String {
        switch self {
        case .proxy: return "providers.source.proxy".localizedStatic()
        case .direct: return "providers.source.disk".localizedStatic()
        case .autoDetected: return "providers.autoDetected".localizedStatic()
        case .monitor(let source): return source.displayName
        case .quotaCache: return "accounts.source.quotaCache".localizedStatic()
        }
    }

    var supportsDisable: Bool {
        switch self {
        case .proxy, .monitor: true
        case .direct, .autoDetected, .quotaCache: false
        }
    }
}

/// Unified data model for account display
struct AccountRowData: Identifiable, Hashable {
    let id: String
    let provider: AIProvider
    let displayName: String       // Email or account identifier
    let menuBarAccountKey: String
    /// 一个 GLM 连接可以含多个独立 API Key；管理仍针对连接，额度按各自规范键展示。
    var quotaAccountKeys: [String]
    let authFileName: String?
    let source: AccountSource
    let status: String?           // "ready", "cooling", "error", etc.
    let statusMessage: String?
    let isDisabled: Bool
    let canDelete: Bool           // Only proxy accounts can be deleted
    let canEdit: Bool             // Whether this account can be edited (GLM only)
    let canSwitch: Bool           // Whether this account can be switched (Antigravity only)
    /// 只允许真实 CPA 文件账号编辑权重；监控账号、运行时 API Key 和插件虚拟账号不走文件字段接口。
    let canEditRoutingWeight: Bool

    // Custom initializer to handle canEdit parameter
    init(
        id: String,
        provider: AIProvider,
        displayName: String,
        menuBarAccountKey: String? = nil,
        quotaAccountKeys: [String]? = nil,
        authFileName: String? = nil,
        source: AccountSource,
        status: String?,
        statusMessage: String?,
        isDisabled: Bool,
        canDelete: Bool,
        canEdit: Bool = false,
        canSwitch: Bool = false,
        canEditRoutingWeight: Bool = false
    ) {
        self.id = id
        self.provider = provider
        self.displayName = displayName
        self.menuBarAccountKey = menuBarAccountKey ?? displayName
        self.quotaAccountKeys = quotaAccountKeys ?? [menuBarAccountKey ?? displayName]
        self.authFileName = authFileName
        self.source = source
        self.status = status
        self.statusMessage = statusMessage
        self.isDisabled = isDisabled
        self.canDelete = canDelete
        self.canEdit = canEdit
        self.canSwitch = canSwitch
        self.canEditRoutingWeight = canEditRoutingWeight
    }


    /// 固定入口遵循已确认的额度归属。歧义管理行没有可固定凭据；缓存行
    /// 仍有自己的键，多 Key 连接则分别提供所有 Key，不把首 Key 代表整条连接。
    var menuBarItems: [MenuBarQuotaItem] {
        quotaAccountKeys.map { MenuBarQuotaItem(provider: provider.rawValue, accountKey: $0) }
    }

    /// 菜单栏与额度刷新共用同一规范身份；展示名称只用于 UI，不能充当请求路由。
    var quotaAccountID: QuotaAccountID {
        QuotaAccountID(provider: provider, accountKey: menuBarAccountKey)
    }

    var canDownloadAuthFile: Bool {
        authFileName != nil
    }

    // MARK: - Factory Methods
    
    /// Create from AuthFile (proxy mode)
    static func from(authFile: AuthFile, provider: AIProvider) -> AccountRowData {
        let name = authFile.email ?? authFile.name
        return AccountRowData(
            id: authFile.id,
            provider: provider,
            displayName: name,
            menuBarAccountKey: authFile.menuBarAccountKey,
            authFileName: authFile.name,
            source: .proxy,
            status: authFile.status,
            statusMessage: authFile.statusMessage,
            isDisabled: authFile.disabled,
            canDelete: true,
            canEditRoutingWeight: authFile.runtimeOnly != true &&
                !(["api-key", "plugin"].contains(authFile.source?.lowercased() ?? "")) &&
                authFile.name.lowercased().hasSuffix(".json")
        )
    }
    
    /// Create from DirectAuthFile (quota-only mode or proxy stopped)
    static func from(directAuthFile: DirectAuthFile) -> AccountRowData {
        let name = directAuthFile.email ?? directAuthFile.filename
        return AccountRowData(
            id: directAuthFile.id,
            provider: directAuthFile.provider,
            displayName: name,
            menuBarAccountKey: directAuthFile.menuBarAccountKey,
            authFileName: directAuthFile.filename,
            source: .direct,
            status: nil,
            statusMessage: nil,
            isDisabled: false,
            canDelete: false
        )
    }
    
    /// Create from auto-detected account (Cursor, Trae)
    /// Cursor/Trae accounts are imported from local IDE databases via "Scan for IDEs";
    /// deleting them removes the imported quota data from Quotio (issue #213).
    static func from(provider: AIProvider, accountKey: String) -> AccountRowData {
        AccountRowData(
            id: "\(provider.rawValue)_\(accountKey)",
            provider: provider,
            displayName: accountKey,
            menuBarAccountKey: accountKey,
            source: .autoDetected,
            status: nil,
            statusMessage: nil,
            isDisabled: false,
            canDelete: provider.isImportedFromLocalIDE
        )
    }

    static func from(
        monitorAccount: MonitorAccount,
        status: String?,
        statusMessage: String?
    ) -> AccountRowData {
        AccountRowData(
            id: monitorAccount.id,
            provider: monitorAccount.provider,
            displayName: monitorAccount.displayName,
            menuBarAccountKey: monitorAccount.accountKey,
            source: .monitor(monitorAccount.source),
            status: status,
            statusMessage: statusMessage,
            isDisabled: monitorAccount.isDisabled,
            canDelete: monitorAccount.canDelete,
            canEdit: monitorAccount.source == .quotioKeychain
                && [.factoryDroid, .openRouter, .amp].contains(monitorAccount.provider)
        )
    }

    func hash(into hasher: inout Hasher) {
        hasher.combine(id)
        hasher.combine(authFileName)
        hasher.combine(isDisabled)
        hasher.combine(status)
    }

    static func == (lhs: AccountRowData, rhs: AccountRowData) -> Bool {
        lhs.id == rhs.id &&
        lhs.authFileName == rhs.authFileName &&
        lhs.isDisabled == rhs.isDisabled &&
        lhs.status == rhs.status
    }
}

// MARK: - AccountRow View

struct AccountRow: View {
    @Environment(\.colorScheme) private var colorScheme
    @Environment(QuotaViewModel.self) private var viewModel
    let account: AccountRowData
    var isActiveInIDE: Bool = false
    var onDelete: (() -> Void)?
    var onEdit: (() -> Void)?
    var onSwitch: (() -> Void)?
    var onToggleDisabled: (() -> Void)?
    var onDownload: (() -> Void)?
    // 套餐属于账号身份，直接跟在名称后；额度工具与删除共用同一操作行。
    var quotaData: ProviderQuotaData?
    var subscriptionInfo: SubscriptionInfo?
    var showsQuotaActions: Bool = false

    /// 行交互与 ViewModel／原生菜单共用选择状态，也支持隔离偏好的离线验证。
    private var settings: MenuBarSettingsManager { viewModel.menuBarSettings }
    @State private var showWarning = false
    @State private var showMaxItemsAlert = false
    @State private var showDeleteConfirmation = false
    @State private var isHovered: Bool = false
    @State private var showWeightSheet = false
    @State private var pendingMenuBarItem: MenuBarQuotaItem?

    private var canEditRoutingWeight: Bool {
        account.canEditRoutingWeight && viewModel.proxyManager.proxyStatus.running && viewModel.apiClient != nil
    }

    private var isMenuBarSelected: Bool {
        account.menuBarItems.contains { settings.isSelected($0) }
    }

    private var maskedDisplayName: String {
        account.displayName.masked(if: settings.hideSensitiveInfo)
    }

    private var statusColor: Color {
        switch account.status {
        // 代理的 active 与 ready 都表示账号可用；只有显式禁用时才使用灰色。
        case "ready", "active": return account.isDisabled ? .gray : .green
        case "cooling", "outdated": return .orange
        case "error": return .red
        default: return .gray
        }
    }

    private var avatarInitial: String {
        let cleaned = account.displayName.trimmingCharacters(in: .whitespacesAndNewlines)
        if let first = cleaned.first, first.isLetter || first.isNumber {
            return String(first).uppercased()
        }
        return ""
    }

    var body: some View {
        HStack(spacing: 12) {
            // Account Identity Avatar
            accountAvatar

            // Account info
            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 6) {
                    Text(maskedDisplayName)
                        .font(.system(size: 13, weight: .medium))
                        .foregroundStyle(.primary)
                        .lineLimit(1)
                    AccountPlanBadge(quotaData: quotaData, subscriptionInfo: subscriptionInfo)
                        .fixedSize()
                }

                HStack(spacing: 6) {
                    // Status indicator (only for proxy accounts)
                    if let status = account.status {
                        Circle()
                            .fill(statusColor)
                            .frame(width: 5.5, height: 5.5)

                        Text(status)
                            .font(.caption)
                            .foregroundStyle(statusColor)

                        Text("•")
                            .font(.caption)
                            .foregroundStyle(.tertiary)
                    }

                    // Source indicator
                    Text(account.source.displayName)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                if let message = account.statusMessage, !message.isEmpty {
                    Text(message)
                        .font(.caption2)
                        .foregroundStyle(account.status == "error" ? .red : .secondary)
                        .lineLimit(1)
                }
                if let expiry = quotaData?.formattedTokenExpiry {
                    // Kiro 的到期信息仍保留在身份元信息中，不因移除第二行工具栏而丢失。
                    Label(expiry, systemImage: "key")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
            }

            Spacer(minLength: 8)

            // Right-side actions & badges
            HStack(spacing: 8) {
                // Disabled badge
                if account.isDisabled {
                    Text("providers.disabled".localized())
                        .font(.caption2.weight(.medium))
                        .padding(.horizontal, 7)
                        .padding(.vertical, 2.5)
                        .background(Capsule().fill(Color.secondary.opacity(0.18)))
                        .foregroundStyle(.secondary)
                }

                // Active in IDE badge (Antigravity only)
                if account.provider == .antigravity && isActiveInIDE {
                    HStack(spacing: 4) {
                        Circle()
                            .fill(Color.green)
                            .frame(width: 5, height: 5)
                        Text("antigravity.active".localized())
                            .font(.caption2.weight(.semibold))
                    }
                    .padding(.horizontal, 8)
                    .padding(.vertical, 3.5)
                    .background(Capsule().fill(Color.green.opacity(colorScheme == .dark ? 0.20 : 0.12)))
                    .overlay(
                        Capsule().strokeBorder(Color.green.opacity(0.35), lineWidth: 0.5)
                    )
                    .foregroundStyle(Color.green)
                }

                // Switch button (Antigravity only, for proxy/direct accounts that are not active)
                if account.provider == .antigravity && !isActiveInIDE && account.source != .autoDetected {
                    Button {
                        onSwitch?()
                    } label: {
                        HStack(spacing: 4) {
                            Image(systemName: "rectangle.portrait.and.arrow.right")
                                .font(.system(size: 9.5))
                            Text("antigravity.useInIDE".localized())
                                .font(.system(size: 11, weight: .medium))
                        }
                    }
                    .buttonStyle(.quotioMicroCapsule(height: 24))
                    .nativeTooltip("antigravity.switch.title".localized())
                    .help("antigravity.switch.title".localized())
                }

                // Menu bar toggle (26pt circular icon button)
                menuBarControl

                // Disable/Enable toggle button (only for proxy accounts)
                if account.source.supportsDisable, let onToggleDisabled = onToggleDisabled {
                    let title = account.isDisabled ? "providers.enable".localized() : "providers.disable".localized()
                    QuotioCircularIconButton(
                        systemImage: account.isDisabled ? "xmark.circle.fill" : "checkmark.circle",
                        tint: account.isDisabled ? .red : .secondary,
                        backgroundTint: account.isDisabled ? .red : nil,
                        tooltip: title
                    ) {
                        onToggleDisabled()
                    }
                    .accessibilityLabel(title)
                }

                // Edit button (GLM only)
                if account.canEdit, let onEdit = onEdit {
                    QuotioCircularIconButton(
                        systemImage: "pencil",
                        tint: .blue,
                        backgroundTint: .blue,
                        tooltip: "action.edit".localized()
                    ) {
                        onEdit()
                    }
                }

                if canEditRoutingWeight {
                    QuotioCircularIconButton(
                        systemImage: "slider.horizontal.3",
                        tint: .blue,
                        backgroundTint: .blue,
                        tooltip: "settings.cpa.accountWeight".localized()
                    ) {
                        showWeightSheet = true
                    }
                    .accessibilityLabel("settings.cpa.accountWeight".localized())
                }

                if showsQuotaActions {
                    AccountQuotaActions(account: account)
                }

                // Delete button (only for proxy accounts)
                if account.canDelete, onDelete != nil {
                    QuotioCircularIconButton(
                        systemImage: "trash",
                        tint: .red,
                        backgroundTint: .red,
                        tooltip: "action.delete".localized()
                    ) {
                        showDeleteConfirmation = true
                    }
                }
            }
            // 操作保持一行且保留完整按钮文案；窄窗口优先截断可悬停查看的账号名称，
            // 不能把“在 IDE 中使用”挤成难以辨认的半句，也不能把预热／刷新移到第二行。
            .fixedSize(horizontal: true, vertical: false)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
        .background(
            isHovered
                ? QuotioTheme.Colors.cardElevated(for: colorScheme).opacity(0.55)
                : Color.clear
        )
        .onHover { hovering in
            withAnimation(.easeInOut(duration: 0.12)) {
                isHovered = hovering
            }
        }
        .contentShape(Rectangle())
        .contextMenu {
            if canEditRoutingWeight {
                Button { showWeightSheet = true } label: {
                    Label("settings.cpa.accountWeight".localized(), systemImage: "slider.horizontal.3")
                }
            }
            // Switch account option (Antigravity only)
            if account.provider == .antigravity && !isActiveInIDE && account.source != .autoDetected {
                Button {
                    onSwitch?()
                } label: {
                    Label("antigravity.switch.title".localized(), systemImage: "arrow.triangle.2.circlepath")
                }
                
                Divider()
            }
            
            if let onDownload {
                Button {
                    onDownload()
                } label: {
                    Label("action.download".localized(), systemImage: "arrow.down.circle")
                }
            }

            // Menu bar toggle
            menuBarButtons

            // Disable/Enable toggle (only for proxy accounts)
            if account.source.supportsDisable, let onToggleDisabled = onToggleDisabled {
                Button {
                    onToggleDisabled()
                } label: {
                    if account.isDisabled {
                        Label("providers.enable".localized(), systemImage: "checkmark.circle")
                    } else {
                        Label("providers.disable".localized(), systemImage: "minus.circle")
                    }
                }
            }

            // Delete option (only for proxy accounts)
            if account.canDelete, onDelete != nil {
                Divider()
                
                Button(role: .destructive) {
                    showDeleteConfirmation = true
                } label: {
                    Label("action.delete".localized(), systemImage: "trash")
                }
            }
        }
        .sheet(isPresented: $showWeightSheet) {
            if let client = viewModel.apiClient, let name = account.authFileName {
                CPAAccountWeightSheet(displayName: maskedDisplayName, authFileName: name, client: client) {
                    // 只刷新账号元数据，不为一次权重修改额外发起所有提供商的额度请求。
                    Task { await viewModel.refreshData(refreshQuotas: false) }
                }
            }
        }
        .confirmationDialog("providers.deleteConfirm".localized(), isPresented: $showDeleteConfirmation) {
            Button("action.delete".localized(), role: .destructive) {
                onDelete?()
            }
            Button("action.cancel".localized(), role: .cancel) {}
        } message: {
            Text("providers.deleteMessage".localized())
        }
        .alert("menubar.warning.title".localized(), isPresented: $showWarning) {
            Button("menubar.warning.confirm".localized()) {
                if let item = pendingMenuBarItem, account.menuBarItems.contains(item) {
                    settings.toggleItem(item)
                }
                pendingMenuBarItem = nil
            }
            Button("menubar.warning.cancel".localized(), role: .cancel) {}
        } message: {
            Text("menubar.warning.message".localized())
        }
        .alert("menubar.maxItems.title".localized(), isPresented: $showMaxItemsAlert) {
            Button("action.ok".localized(), role: .cancel) {}
        } message: {
            Text(String(
                format: "menubar.maxItems.message".localized(),
                settings.menuBarMaxItems
            ))
        }
    }

    private var accountAvatar: some View {
        ZStack {
            Circle()
                .fill(account.provider.color.opacity(colorScheme == .dark ? 0.22 : 0.12))
                .overlay(
                    Circle().strokeBorder(account.provider.color.opacity(0.35), lineWidth: 0.5)
                )

            if !avatarInitial.isEmpty {
                Text(avatarInitial)
                    .font(.system(size: 12, weight: .bold, design: .rounded))
                    .foregroundStyle(account.provider.color)
            } else {
                Image(systemName: "person.fill")
                    .font(.system(size: 11))
                    .foregroundStyle(account.provider.color)
            }
        }
        .frame(width: 28, height: 28)
    }
    
    @ViewBuilder private var menuBarControl: some View {
        if account.menuBarItems.count > 1 {
            // 同一连接只占原有一个图标；下拉逐 Key 固定，标签仅用安全序号，
            // 不显示密钥、内部凭据键或被隐私设置隐藏的账号名。
            let title = isMenuBarSelected ? "menubar.hideFromMenuBar".localized() : "menubar.showOnMenuBar".localized()
            Menu { menuBarButtons } label: {
                Image(systemName: isMenuBarSelected ? "chart.bar.fill" : "chart.bar")
                    .font(.system(size: 11.5, weight: .medium))
                    .foregroundStyle(isMenuBarSelected ? .blue : .secondary)
                    .frame(width: 26, height: 26)
                    .background(isMenuBarSelected ? Color.blue.opacity(0.12) : Color.secondary.opacity(0.08), in: Circle())
            }
            .menuStyle(.borderlessButton).menuIndicator(.hidden).fixedSize()
            .nativeTooltip(title)
            .help(title)
            .accessibilityLabel("menubar.showOnMenuBar".localized())
        } else {
            MenuBarBadge(isSelected: isMenuBarSelected, onTap: {
                if let item = account.menuBarItems.first { handleMenuBarToggle(item) }
            })
            .disabled(account.menuBarItems.isEmpty)
        }
    }

    @ViewBuilder private var menuBarButtons: some View {
        ForEach(account.menuBarItems) { item in
            Button { handleMenuBarToggle(item) } label: {
                if account.menuBarItems.count > 1 {
                    Label(String(format: "accounts.menuBar.key".localized(),
                        Int64((account.menuBarItems.firstIndex(of: item) ?? 0) + 1)),
                        systemImage: settings.isSelected(item) ? "checkmark.circle.fill" : "circle")
                } else {
                    Label((settings.isSelected(item) ? "menubar.hideFromMenuBar" : "menubar.showOnMenuBar").localized(),
                          systemImage: settings.isSelected(item) ? "chart.bar" : "chart.bar.fill")
                }
            }
        }
    }

    private func handleMenuBarToggle(_ item: MenuBarQuotaItem) {
        guard account.menuBarItems.contains(item) else { return }
        pendingMenuBarItem = item
        if settings.isSelected(item) {
            settings.toggleItem(item)
        } else if settings.isAtMaxItems {
            showMaxItemsAlert = true
        } else if settings.shouldWarnOnAdd {
            showWarning = true
        } else {
            settings.toggleItem(item)
        }
    }
}

// MARK: - Preview

#Preview {
    List {
        AccountRow(
            account: AccountRowData(
                id: "1",
                provider: .antigravity,
                displayName: "user@gmail.com",
                source: .proxy,
                status: "ready",
                statusMessage: nil,
                isDisabled: false,
                canDelete: true
            ),
            onDelete: {}
        )
        
        AccountRow(
            account: AccountRowData(
                id: "2",
                provider: .claude,
                displayName: "work@company.com",
                source: .direct,
                status: nil,
                statusMessage: nil,
                isDisabled: false,
                canDelete: false
            )
        )
        
        AccountRow(
            account: AccountRowData(
                id: "3",
                provider: .cursor,
                displayName: "dev@example.com",
                source: .autoDetected,
                status: nil,
                statusMessage: nil,
                isDisabled: false,
                canDelete: false
            )
        )
    }
}
