//
//  ProviderDisclosureGroup.swift
//  Quotio
//
//  Collapsible group for displaying accounts grouped by provider.
//  Part of ProvidersScreen UI/UX redesign.
//

import SwiftUI

// MARK: - Provider Disclosure Group

/// A collapsible squircle card that displays all accounts for a specific provider
/// adhering to the macOS 26 fluid design standard (外方内圆, zero dividers, inset well).
struct ProviderDisclosureGroup: View {
    @Environment(\.colorScheme) private var colorScheme
    let provider: AIProvider
    let accounts: [AccountRowData]
    var onDeleteAccount: ((AccountRowData) -> Void)?
    var onEditAccount: ((AccountRowData) -> Void)?
    var onSwitchAccount: ((AccountRowData) -> Void)?
    var onToggleDisabled: ((AccountRowData) -> Void)?
    var onDownloadAccount: ((AccountRowData) -> Void)?
    var isAccountActive: ((AccountRowData) -> Bool)?

    @State private var isExpanded: Bool = true
    @State private var isHeaderHovered: Bool = false

    /// Check if all accounts in this group are auto-detected
    private var isAllAutoDetected: Bool {
        accounts.allSatisfy { $0.source == .autoDetected }
    }

    /// Accounts with the ones currently in use floated to the top,
    /// keeping the existing order as the tie-breaker.
    private var displayedAccounts: [AccountRowData] {
        guard let isAccountActive else { return accounts }
        return AccountSorting.prioritizingActive(accounts, isActive: isAccountActive)
    }

    var body: some View {
        VStack(spacing: 0) {
            // Card Header Button
            Button {
                withAnimation(.spring(response: 0.32, dampingFraction: 0.80)) {
                    isExpanded.toggle()
                }
            } label: {
                providerHeader
            }
            .buttonStyle(.plain)
            .onHover { hovering in
                withAnimation(.easeInOut(duration: 0.12)) {
                    isHeaderHovered = hovering
                }
            }

            // Expanded Accounts List (Clean Inset Grouped layout with hairline dividers)
            if isExpanded {
                Rectangle()
                    .fill(QuotioTheme.Colors.sidebarBorder(for: colorScheme).opacity(0.75))
                    .frame(height: 0.5)

                accountsList
                    .transition(.opacity.combined(with: .move(edge: .top)))
            }
        }
        .background(
            QuotioTheme.Colors.cardBackground(for: colorScheme),
            in: RoundedRectangle(cornerRadius: QuotioTheme.Radius.lg, style: .continuous)
        )
        .overlay(
            RoundedRectangle(cornerRadius: QuotioTheme.Radius.lg, style: .continuous)
                .strokeBorder(QuotioTheme.Colors.sidebarBorder(for: colorScheme), lineWidth: 0.5)
        )
        .clipShape(RoundedRectangle(cornerRadius: QuotioTheme.Radius.lg, style: .continuous))
    }

    // MARK: - Provider Header

    private var providerHeader: some View {
        HStack(spacing: 10) {
            // Provider icon
            ProviderIcon(provider: provider, size: 22)

            // Provider name
            Text(provider.displayName)
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(.primary)

            // Account count badge with brand tint
            Text("\(accounts.count)")
                .font(.caption2.bold().monospacedDigit())
                .padding(.horizontal, 7)
                .padding(.vertical, 2.5)
                .background(provider.color.opacity(colorScheme == .dark ? 0.22 : 0.12), in: Capsule())
                .foregroundStyle(provider.color)
                .overlay(
                    Capsule()
                        .strokeBorder(provider.color.opacity(0.3), lineWidth: 0.5)
                )

            Spacer()

            // Auto-detected indicator (when all accounts are auto-detected)
            if isAllAutoDetected {
                HStack(spacing: 4) {
                    Image(systemName: "sparkles")
                        .font(.system(size: 10))
                    Text("providers.autoDetected".localized())
                        .font(.caption2.weight(.medium))
                }
                .foregroundStyle(.secondary)
                .padding(.horizontal, 8)
                .padding(.vertical, 3)
                .background(QuotioTheme.Colors.cardInset(for: colorScheme), in: Capsule())
                .overlay(
                    Capsule()
                        .strokeBorder(QuotioTheme.Colors.sidebarBorder(for: colorScheme), lineWidth: 0.5)
                )
            }

            // Smooth rotating chevron indicator
            Image(systemName: "chevron.right")
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(.tertiary)
                .rotationEffect(.degrees(isExpanded ? 90 : 0))
                .padding(.leading, 4)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 12)
        .background(
            isHeaderHovered
                ? QuotioTheme.Colors.cardElevated(for: colorScheme).opacity(0.5)
                : Color.clear
        )
        .contentShape(Rectangle())
    }

    // MARK: - Accounts List (Zero Div-Soup, Inset Grouped)

    private var accountsList: some View {
        VStack(spacing: 0) {
            ForEach(Array(displayedAccounts.enumerated()), id: \.element.id) { index, account in
                if index > 0 {
                    Rectangle()
                        .fill(QuotioTheme.Colors.sidebarBorder(for: colorScheme).opacity(0.65))
                        .frame(height: 0.5)
                        .padding(.leading, 54)
                }

                AccountRow(
                    account: account,
                    isActiveInIDE: isAccountActive?(account) ?? false,
                    onDelete: onDeleteAccount != nil ? { onDeleteAccount?(account) } : nil,
                    onEdit: onEditAccount != nil ? { onEditAccount?(account) } : nil,
                    onSwitch: onSwitchAccount != nil ? { onSwitchAccount?(account) } : nil,
                    onToggleDisabled: onToggleDisabled != nil ? { onToggleDisabled?(account) } : nil,
                    onDownload: account.canDownloadAuthFile && onDownloadAccount != nil
                        ? { onDownloadAccount?(account) }
                        : nil,
                    isLastRow: index == displayedAccounts.count - 1
                )
            }
        }
    }
}

// MARK: - Preview

#Preview {
    List {
        ProviderDisclosureGroup(
            provider: .antigravity,
            accounts: [
                AccountRowData(
                    id: "1",
                    provider: .antigravity,
                    displayName: "user@gmail.com",
                    source: .proxy,
                    status: "ready",
                    statusMessage: nil,
                    isDisabled: false,
                    canDelete: true
                ),
                AccountRowData(
                    id: "2",
                    provider: .antigravity,
                    displayName: "work@company.com",
                    source: .proxy,
                    status: "cooling",
                    statusMessage: "Rate limited",
                    isDisabled: false,
                    canDelete: true
                )
            ]
        )
        
        ProviderDisclosureGroup(
            provider: .cursor,
            accounts: [
                AccountRowData(
                    id: "3",
                    provider: .cursor,
                    displayName: "dev@example.com",
                    source: .autoDetected,
                    status: nil,
                    statusMessage: nil,
                    isDisabled: false,
                    canDelete: false
                )
            ]
        )
    }
}
