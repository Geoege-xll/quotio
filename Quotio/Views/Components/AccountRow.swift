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
    
    var displayName: String {
        switch self {
        case .proxy: return "providers.source.proxy".localizedStatic()
        case .direct: return "providers.source.disk".localizedStatic()
        case .autoDetected: return "providers.autoDetected".localizedStatic()
        case .monitor(let source): return source.displayName
        }
    }

    var supportsDisable: Bool {
        switch self {
        case .proxy, .monitor: true
        case .direct, .autoDetected: false
        }
    }
}

/// Unified data model for account display
struct AccountRowData: Identifiable, Hashable {
    let id: String
    let provider: AIProvider
    let displayName: String       // Email or account identifier
    let menuBarAccountKey: String
    let authFileName: String?
    let source: AccountSource
    let status: String?           // "ready", "cooling", "error", etc.
    let statusMessage: String?
    let isDisabled: Bool
    let canDelete: Bool           // Only proxy accounts can be deleted
    let canEdit: Bool             // Whether this account can be edited (GLM only)
    let canSwitch: Bool           // Whether this account can be switched (Antigravity only)

    // Custom initializer to handle canEdit parameter
    init(
        id: String,
        provider: AIProvider,
        displayName: String,
        menuBarAccountKey: String? = nil,
        authFileName: String? = nil,
        source: AccountSource,
        status: String?,
        statusMessage: String?,
        isDisabled: Bool,
        canDelete: Bool,
        canEdit: Bool = false,
        canSwitch: Bool = false
    ) {
        self.id = id
        self.provider = provider
        self.displayName = displayName
        self.menuBarAccountKey = menuBarAccountKey ?? displayName
        self.authFileName = authFileName
        self.source = source
        self.status = status
        self.statusMessage = statusMessage
        self.isDisabled = isDisabled
        self.canDelete = canDelete
        self.canEdit = canEdit
        self.canSwitch = canSwitch
    }

    // For menu bar selection
    var menuBarItem: MenuBarQuotaItem {
        MenuBarQuotaItem(provider: provider.rawValue, accountKey: menuBarAccountKey)
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
            canDelete: true
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
    let account: AccountRowData
    var isActiveInIDE: Bool = false
    var onDelete: (() -> Void)?
    var onEdit: (() -> Void)?
    var onSwitch: (() -> Void)?
    var onToggleDisabled: (() -> Void)?
    var onDownload: (() -> Void)?
    var isLastRow: Bool = false

    @State private var settings = MenuBarSettingsManager.shared
    @State private var showWarning = false
    @State private var showMaxItemsAlert = false
    @State private var showDeleteConfirmation = false
    @State private var isHovered: Bool = false

    private var isMenuBarSelected: Bool {
        settings.isSelected(account.menuBarItem)
    }

    private var maskedDisplayName: String {
        account.displayName.masked(if: settings.hideSensitiveInfo)
    }

    private var statusColor: Color {
        switch account.status {
        case "ready": return account.isDisabled ? .gray : .green
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
                Text(maskedDisplayName)
                    .font(.system(size: 13, weight: .medium))
                    .foregroundStyle(.primary)
                    .lineLimit(1)

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
                    .help("antigravity.switch.title".localized())
                }

                // Menu bar toggle (26pt circular icon button)
                MenuBarBadge(
                    isSelected: isMenuBarSelected,
                    onTap: handleMenuBarToggle
                )

                // Disable/Enable toggle button (only for proxy accounts)
                if account.source.supportsDisable, let onToggleDisabled = onToggleDisabled {
                    QuotioCircularIconButton(
                        systemImage: account.isDisabled ? "xmark.circle.fill" : "checkmark.circle",
                        tint: account.isDisabled ? .red : .secondary,
                        backgroundTint: account.isDisabled ? .red : nil
                    ) {
                        onToggleDisabled()
                    }
                    .help(account.isDisabled ? "providers.enable".localized() : "providers.disable".localized())
                    .accessibilityLabel(account.isDisabled ? "providers.enable".localized() : "providers.disable".localized())
                }

                // Edit button (GLM only)
                if account.canEdit, let onEdit = onEdit {
                    QuotioCircularIconButton(
                        systemImage: "pencil",
                        tint: .blue,
                        backgroundTint: .blue
                    ) {
                        onEdit()
                    }
                    .help("action.edit".localized())
                }

                // Delete button (only for proxy accounts)
                if account.canDelete, onDelete != nil {
                    QuotioCircularIconButton(
                        systemImage: "trash",
                        tint: .red,
                        backgroundTint: .red
                    ) {
                        showDeleteConfirmation = true
                    }
                    .help("action.delete".localized())
                }
            }
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
            Button {
                handleMenuBarToggle()
            } label: {
                if isMenuBarSelected {
                    Label("menubar.hideFromMenuBar".localized(), systemImage: "chart.bar")
                } else {
                    Label("menubar.showOnMenuBar".localized(), systemImage: "chart.bar.fill")
                }
            }

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
                settings.toggleItem(account.menuBarItem)
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
        ZStack(alignment: .bottomTrailing) {
            Circle()
                .fill(account.provider.color.opacity(colorScheme == .dark ? 0.22 : 0.12))
                .overlay(
                    Circle().strokeBorder(account.provider.color.opacity(0.35), lineWidth: 0.5)
                )
                .frame(width: 28, height: 28)

            if !avatarInitial.isEmpty {
                Text(avatarInitial)
                    .font(.system(size: 12, weight: .bold, design: .rounded))
                    .foregroundStyle(account.provider.color)
            } else {
                Image(systemName: "person.fill")
                    .font(.system(size: 11))
                    .foregroundStyle(account.provider.color)
            }

            // Status dot badge on bottom right
            if account.status != nil {
                Circle()
                    .fill(statusColor)
                    .frame(width: 7, height: 7)
                    .overlay(
                        Circle()
                            .stroke(QuotioTheme.Colors.cardBackground(for: colorScheme), lineWidth: 1.5)
                    )
                    .offset(x: 1.5, y: 1.5)
            }
        }
        .frame(width: 28, height: 28)
    }
    
    private func handleMenuBarToggle() {
        if isMenuBarSelected {
            settings.toggleItem(account.menuBarItem)
        } else if settings.isAtMaxItems {
            showMaxItemsAlert = true
        } else if settings.shouldWarnOnAdd {
            showWarning = true
        } else {
            settings.toggleItem(account.menuBarItem)
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
