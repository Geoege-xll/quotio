import SwiftUI

/// 账号行内的额度工具，与菜单栏固定、启停和删除并列。
/// 按账号的规范额度键请求；多密钥连接保留逐 Key 刷新选项，预热仍使用原有弹窗。
struct AccountQuotaActions: View {
    @Environment(QuotaViewModel.self) private var viewModel
    @Environment(\.colorScheme) private var colorScheme
    let account: AccountRowData
    @State private var showsWarmup = false

    private var isRefreshing: Bool {
        viewModel.isRefreshing(provider: account.provider) || account.quotaAccountKeys.contains {
            viewModel.isRefreshing(account: QuotaAccountID(provider: account.provider, accountKey: $0))
        }
    }

    private func isBlocked(_ key: String) -> Bool {
        !viewModel.supportsScopedRefresh(for: account.provider)
            || viewModel.isRefreshBlocked(for: QuotaAccountID(provider: account.provider, accountKey: key))
    }

    private func refresh(_ key: String) {
        Task { await viewModel.refreshQuota(for: QuotaAccountID(provider: account.provider, accountKey: key)) }
    }

    var body: some View {
        HStack(spacing: 8) {
            if account.provider == .antigravity, let key = account.quotaAccountKeys.first {
                let enabled = viewModel.isWarmupEnabled(for: account.provider, accountKey: key)
                QuotioCircularIconButton(systemImage: enabled ? "bolt.fill" : "bolt",
                    tint: enabled ? account.provider.color : .secondary,
                    backgroundTint: enabled ? account.provider.color : nil,
                    tooltip: "action.warmup".localized()) {
                    showsWarmup = true
                }
                .accessibilityLabel("action.warmup".localized())
                .accessibilityIdentifier("accounts.action.warmup")
                .sheet(isPresented: $showsWarmup) {
                    WarmupSheet(provider: account.provider, accountKey: key, accountEmail: account.displayName,
                        onDismiss: { showsWarmup = false })
                        .environment(viewModel)
                }
            }

            if account.quotaAccountKeys.count > 1 {
                // 多 Key 额度段可以分别刷新；序号由配置顺序产生，不读取或展示密钥内容。
                Menu {
                    ForEach(Array(account.quotaAccountKeys.enumerated()), id: \.element) { index, key in
                        Button("\("action.refresh".localized()) · \(index + 1)") { refresh(key) }
                            .disabled(isBlocked(key))
                    }
                } label: { refreshIcon }
                .menuStyle(.borderlessButton)
                .fixedSize()
                .nativeTooltip("action.refreshQuota".localized())
                .help("action.refreshQuota".localized())
                .accessibilityLabel("action.refreshQuota".localized())
                .accessibilityIdentifier("accounts.action.refresh")
            } else if let key = account.quotaAccountKeys.first {
                Button { refresh(key) } label: { refreshIcon }
                    .buttonStyle(TactileCircularButtonStyle())
                    .disabled(isBlocked(key))
                    .nativeTooltip("action.refreshQuota".localized())
                    .help("action.refreshQuota".localized())
                    .accessibilityLabel("action.refreshQuota".localized())
                    .accessibilityIdentifier("accounts.action.refresh")
            }
        }
    }

    private var refreshIcon: some View {
        Group {
            if isRefreshing {
                ProgressView().controlSize(.mini)
            } else {
                Image(systemName: "arrow.clockwise")
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(.secondary)
            }
        }
        .frame(width: 26, height: 26)
        .background(QuotioTheme.Colors.cardInset(for: colorScheme), in: Circle())
        .contentShape(Circle())
    }
}
