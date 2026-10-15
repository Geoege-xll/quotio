import SwiftUI

/// 一个服务商组内直接融合账号身份、管理操作和完整额度；筛选只改变列表，不生成 Tab。
/// 操作始终回传原始 AccountRowData，使编辑、删除、导出仍使用既有存储 ID 与权限。
struct AccountProviderGroups: View {
    @Environment(QuotaViewModel.self) private var viewModel
    let groups: [AIProvider: [AccountRowData]]
    let selection: AIProvider?
    let quotaDisplayStyle: QuotaDisplayStyle
    var onDelete: ((AccountRowData) -> Void)?
    var onEdit: ((AccountRowData) -> Void)?
    var onSwitch: ((AccountRowData) -> Void)?
    var onToggleDisabled: ((AccountRowData) -> Void)?
    var onDownload: ((AccountRowData) -> Void)?

    var visibleProviders: [AIProvider] {
        groups.keys.filter { selection == nil || $0 == selection }
            .sorted { $0.displayName < $1.displayName }
    }

    var body: some View {
        VStack(spacing: 10) {
            ForEach(visibleProviders) { provider in
                ProviderDisclosureGroup(
                    provider: provider,
                    accounts: groups[provider] ?? [],
                    quotaDisplayStyle: quotaDisplayStyle,
                    onDeleteAccount: onDelete,
                    onEditAccount: onEdit,
                    onSwitchAccount: provider == .antigravity ? onSwitch : nil,
                    onToggleDisabled: onToggleDisabled,
                    onDownloadAccount: onDownload,
                    isAccountActive: provider == .antigravity ? { account in
                        viewModel.isAntigravityAccountActive(email: account.displayName)
                    } : nil
                )
                .accessibilityIdentifier("accounts.group." + provider.rawValue)
            }
        }
    }
}
