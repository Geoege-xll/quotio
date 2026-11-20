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
    case proxy           // CPA 确认的认证目录
    case direct          // 用户手动配置的密钥或连接
    case autoDetected    // 用户主动扫描并导入的 Cursor 或 Trae 账号
    
    var displayName: String {
        switch self {
        case .proxy: return "providers.source.proxy".localizedStatic()
        case .direct: return "providers.source.disk".localizedStatic()
        case .autoDetected: return "accounts.source.importedIDE".localizedStatic()
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
    /// 离线快照仍保留真实身份、状态和规范键，只有当前 CPA 会话已确认目录后才开放操作。
    let canManageCPA: Bool
    /// 只允许真实 CPA 文件账号编辑权重；运行时 API Key 和插件虚拟账号不走文件字段接口。
    let canEditRoutingWeight: Bool
    let authIndex: String?
    let weight: Int?
    let priority: Int?
    let cooldowns: [AuthFileCooldown]?

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
        canManageCPA: Bool = true,
        canEditRoutingWeight: Bool = false,
        authIndex: String? = nil,
        weight: Int? = nil,
        priority: Int? = nil,
        cooldowns: [AuthFileCooldown]? = nil
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
        self.canManageCPA = source == .proxy && canManageCPA
        self.canEditRoutingWeight = canEditRoutingWeight
        self.authIndex = authIndex
        self.weight = weight
        self.priority = priority
        self.cooldowns = cooldowns
    }

    /// 原成员保留兼容调用；可见行显式传入 Timeline 的时间，不触发网络或额度刷新。
    var activeCooldowns: [AuthFileCooldown] { activeCooldowns(at: Date()) }
    var hasActiveCooldown: Bool { !activeCooldowns.isEmpty }
    var cooldownSummary: String? { AuthFileCooldown.summary(activeCooldowns) }
    var cooldownTooltip: String? { AuthFileCooldown.tooltip(activeCooldowns) }
    var canResetCooldown: Bool { canResetCooldown(at: Date()) }

    func activeCooldowns(at date: Date) -> [AuthFileCooldown] { AuthFileCooldown.active(cooldowns, at: date) }
    func canResetCooldown(at date: Date) -> Bool {
        canManageCPA && !activeCooldowns(at: date).isEmpty
            && authIndex?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false
    }

    /// 固定入口遵循已确认的额度归属。歧义管理行没有可固定凭据，多 Key 连接逐 Key 固定。
    var menuBarItems: [MenuBarQuotaItem] {
        quotaAccountKeys.map { MenuBarQuotaItem(provider: provider.rawValue, accountKey: $0) }
    }

    /// 菜单栏与额度刷新共用同一规范身份；展示名称只用于 UI，不能充当请求路由。
    var quotaAccountID: QuotaAccountID {
        QuotaAccountID(provider: provider, accountKey: menuBarAccountKey)
    }

    var canDownloadAuthFile: Bool {
        canManageCPA && authFileName != nil
    }

    // MARK: - Factory Methods
    
    /// 当前目录和离线目录采用同一规范键；快照权限与原身份字段独立。
    static func from(authFile: AuthFile, provider: AIProvider, canManage: Bool = true) -> AccountRowData {
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
            canDelete: canManage,
            canManageCPA: canManage,
            canEditRoutingWeight: canManage && authFile.runtimeOnly != true &&
                !(["api-key", "plugin"].contains(authFile.source?.lowercased() ?? "")) &&
                authFile.name.lowercased().hasSuffix(".json"),
            authIndex: authFile.authIndex,
            weight: authFile.weight,
            priority: authFile.priority,
            cooldowns: authFile.cooldowns
        )
    }
    
    /// Cursor 和 Trae 账号由用户主动扫描导入。删除时只移除 Quotio 已保存的导入数据。
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

    func hash(into hasher: inout Hasher) {
        hasher.combine(id)
        hasher.combine(authFileName)
        hasher.combine(isDisabled)
        hasher.combine(canManageCPA)
        hasher.combine(status)
        hasher.combine(authIndex)
        hasher.combine(weight)
        hasher.combine(priority)
        hasher.combine(cooldowns)
    }

    static func == (lhs: AccountRowData, rhs: AccountRowData) -> Bool {
        lhs.id == rhs.id &&
        lhs.authFileName == rhs.authFileName &&
        lhs.isDisabled == rhs.isDisabled &&
        lhs.canManageCPA == rhs.canManageCPA &&
        lhs.status == rhs.status &&
        lhs.authIndex == rhs.authIndex &&
        lhs.weight == rhs.weight &&
        lhs.priority == rhs.priority &&
        lhs.cooldowns == rhs.cooldowns
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

    /// 同时校验目录行及实时会话，覆盖菜单已经打开或确认弹窗尚未关闭时代理停止的情况。
    private var canManageCPA: Bool {
        account.canManageCPA && viewModel.hasCurrentCPAAccountDirectory
    }

    private var canEditRoutingWeight: Bool {
        account.canEditRoutingWeight && canManageCPA
    }

    private var canSwitchAntigravity: Bool {
        account.provider == .antigravity && !isActiveInIDE && canManageCPA && onSwitch != nil
    }

    private var canDeleteAccount: Bool {
        account.canDelete && (account.source != .proxy || canManageCPA)
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
        // 只有含冷却数据的可见行提供一秒级展示时钟；不新增 VM Task 或后台取数。
        if account.cooldowns?.isEmpty == false {
            TimelineView(.periodic(from: .now, by: 1)) { timeline in
                rowContent(at: timeline.date)
            }
        } else { rowContent(at: .now) }
    }

    private func rowContent(at date: Date) -> some View {
        let activeCooldowns = account.activeCooldowns(at: date)
        return HStack(spacing: 12) {
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
                    if let priority = account.priority, priority > 0 {
                        Text("P\(priority)")
                            .font(.system(size: 10, weight: .bold, design: .rounded))
                            .padding(.horizontal, 5)
                            .padding(.vertical, 1.5)
                            .background(Capsule().fill(Color.purple.opacity(colorScheme == .dark ? 0.22 : 0.12)))
                            .foregroundStyle(.purple)
                            .nativeTooltip(String(format: "credentials.priority.badgeTooltip".localized(), priority))
                            .help(String(format: "credentials.priority.badgeTooltip".localized(), priority))
                    }
                    if let summary = AuthFileCooldown.summary(activeCooldowns) {
                        HStack(spacing: 3) {
                            Image(systemName: "snowflake")
                                .font(.system(size: 8.5))
                            Text(summary)
                                .font(.system(size: 9.5, weight: .medium))
                        }
                        .padding(.horizontal, 6)
                        .padding(.vertical, 1.5)
                        .background(Capsule().fill(Color.orange.opacity(colorScheme == .dark ? 0.22 : 0.12)))
                        .foregroundStyle(.orange)
                        .nativeTooltip(AuthFileCooldown.tooltip(activeCooldowns) ?? "")
                        .help(AuthFileCooldown.tooltip(activeCooldowns) ?? "")
                    }
                }

                HStack(spacing: 6) {
                    // Status indicator (only for proxy accounts)
                    if let status = account.status,
                       canManageCPA || !["ready", "active"].contains(status) {
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
                if account.provider == .antigravity && isActiveInIDE && canManageCPA {
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
                if canSwitchAntigravity {
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

                // Cooldown reset button
                if canManageCPA && account.canResetCooldown(at: date) {
                    QuotioCircularIconButton(
                        systemImage: "arrow.counterclockwise",
                        tint: .orange,
                        backgroundTint: .orange,
                        tooltip: "credentials.cooldown.reset".localized()
                    ) {
                        if let authIndex = account.authIndex {
                            Task {
                                await viewModel.resetAuthFileCooldown(authIndex: authIndex)
                            }
                        }
                    }
                    .accessibilityLabel("credentials.cooldown.reset".localized())
                }

                // Disable/Enable toggle button (only for proxy accounts)
                if canManageCPA, let onToggleDisabled {
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
                        tooltip: "settings.cpa.accountRouting".localized()
                    ) {
                        showWeightSheet = true
                    }
                    .accessibilityLabel("settings.cpa.accountRouting".localized())
                }

                if showsQuotaActions {
                    AccountQuotaActions(account: account)
                }

                // Delete button (only for proxy accounts)
                if canDeleteAccount, onDelete != nil {
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
            if canManageCPA && account.canResetCooldown(at: date) {
                Button {
                    if let authIndex = account.authIndex {
                        Task { await viewModel.resetAuthFileCooldown(authIndex: authIndex) }
                    }
                } label: {
                    Label("credentials.cooldown.reset".localized(), systemImage: "arrow.counterclockwise")
                }
            }

            if canEditRoutingWeight {
                Button { showWeightSheet = true } label: {
                    Label("settings.cpa.accountRouting".localized(), systemImage: "slider.horizontal.3")
                }
            }
            // Switch account option (Antigravity only)
            if canSwitchAntigravity {
                Button {
                    onSwitch?()
                } label: {
                    Label("antigravity.switch.title".localized(), systemImage: "arrow.triangle.2.circlepath")
                }
                
                Divider()
            }
            
            if canManageCPA, let onDownload {
                Button {
                    onDownload()
                } label: {
                    Label("action.download".localized(), systemImage: "arrow.down.circle")
                }
            }

            // Menu bar toggle
            menuBarButtons

            // Disable/Enable toggle (only for proxy accounts)
            if canManageCPA, let onToggleDisabled {
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
            if canDeleteAccount, onDelete != nil {
                Divider()
                
                Button(role: .destructive) {
                    showDeleteConfirmation = true
                } label: {
                    Label("action.delete".localized(), systemImage: "trash")
                }
            }
        }
        .sheet(isPresented: $showWeightSheet) {
            if canEditRoutingWeight, let client = viewModel.apiClient, let name = account.authFileName {
                CPAAccountWeightSheet(displayName: maskedDisplayName, authFileName: name, client: client) {
                    // 只刷新账号元数据，不为一次权重修改额外发起所有提供商的额度请求。
                    Task { await viewModel.refreshData(refreshQuotas: false) }
                }
            }
        }
        .onChange(of: canManageCPA) { _, canManage in
            if !canManage { showWeightSheet = false }
        }
        .confirmationDialog("providers.deleteConfirm".localized(), isPresented: $showDeleteConfirmation) {
            Button("action.delete".localized(), role: .destructive) {
                if canDeleteAccount { onDelete?() }
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
