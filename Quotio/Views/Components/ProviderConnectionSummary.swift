import SwiftUI

/// 提供商页顶部沿用原仪表盘的同一条流式布局；这里只展示现有账号统计和转发添加意图。
struct ProviderConnectionSummary: View {
    @Environment(QuotaViewModel.self) private var viewModel
    @Environment(\.colorScheme) private var colorScheme
    let onAdd: (AIProvider) -> Void

    var body: some View {
        FlowLayout(spacing: 8) {
            ForEach(viewModel.connectedProviders) { provider in
                ProviderChip(provider: provider, count: viewModel.authFilesByProvider[provider]?.count ?? 0)
            }
            ForEach(viewModel.disconnectedProviders.filter(\.supportsLocalProxySetup)) { provider in
                DisconnectedProviderButton(provider: provider) {
                    onAdd(provider)
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

private struct DisconnectedProviderButton: View {
    @Environment(\.colorScheme) private var colorScheme
    let provider: AIProvider
    let action: () -> Void

    @State private var isHovered = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: 5) {
                Image(systemName: "plus.circle")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Text(provider.displayName)
                    .font(.caption.weight(.medium))
            }
            .foregroundStyle(Color.secondary)
            .padding(.horizontal, 10)
            .padding(.vertical, 6)
            .background(
                isHovered
                    ? QuotioTheme.Colors.cardElevated(for: colorScheme).opacity(0.8)
                    : QuotioTheme.Colors.cardInset(for: colorScheme),
                in: Capsule()
            )
            .overlay(
                Capsule()
                    .strokeBorder(
                        isHovered
                            ? QuotioTheme.Colors.sidebarBorder(for: colorScheme).opacity(0.8)
                            : QuotioTheme.Colors.sidebarBorder(for: colorScheme),
                        lineWidth: 0.5
                    )
            )
            .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .onHover { hovering in
            withAnimation(.easeInOut(duration: 0.12)) {
                isHovered = hovering
            }
        }
    }
}
