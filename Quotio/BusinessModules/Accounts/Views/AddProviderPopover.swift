//
//  AddProviderPopover.swift
//  Quotio
//
//  Popover with grid layout for adding new provider accounts.
//  Part of ProvidersScreen UI/UX redesign.
//

import SwiftUI

// MARK: - Add Provider Popover

struct AddProviderPopover: View {
    @Environment(\.colorScheme) private var colorScheme

    let providers: [AIProvider]
    let existingCounts: [AIProvider: Int]  // Number of existing accounts per provider
    var onSelectProvider: (AIProvider) -> Void
    var onScanIDEs: () -> Void
    var onAddOfficialOpenAI: (() -> Void)? = nil
    var onAddCustomProvider: () -> Void
    var onDismiss: () -> Void

    private let columns = [
        GridItem(.adaptive(minimum: 80), spacing: 12)
    ]

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            // Header with close button
            HStack(alignment: .top) {
                VStack(alignment: .leading, spacing: 2) {
                    Text("providers.addAccount".localized())
                        .font(.headline)

                    // Hint: can add multiple accounts
                    Text("providers.addMultipleHint".localized())
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                Spacer()

                // Close button (26pt circular target per design spec)
                QuotioCircularIconButton(systemImage: "xmark") {
                    onDismiss()
                }
                .keyboardShortcut(.escape)
                .accessibilityLabel("action.cancel".localized())
            }

            // Provider grid with scroll container for responsive height
            ScrollView(.vertical, showsIndicators: true) {
                LazyVGrid(columns: columns, spacing: 12) {
                    // 只在调用方提供官方入口时显示。复用 Codex 已有的 OpenAI 图标与品牌色，
                    // 卡片使用独立标题和官方表单回调，账号数量也与 Codex 条目分开。
                    if let onAddOfficialOpenAI {
                        ProviderButton(
                            provider: .codex,
                            title: "OpenAI",
                            existingCount: 0,
                            showsKeyboardFocus: true
                        ) {
                            // 先登记打开表单的意图，再关闭选择器，由账号页在关闭完成后展示表单。
                            onAddOfficialOpenAI()
                            onDismiss()
                        }
                    }

                    ForEach(providers) { provider in
                        ProviderButton(
                            provider: provider,
                            title: provider.displayName,
                            existingCount: existingCounts[provider] ?? 0
                        ) {
                            onSelectProvider(provider)
                            onDismiss()
                        }
                    }
                }
                .padding(.vertical, 2)
            }
            .frame(maxHeight: 320)

            // Inset well for utility entries (zero-divider architecture)
            VStack(spacing: 6) {
                // Scan for IDEs option
                Button {
                    onScanIDEs()
                    onDismiss()
                } label: {
                    HStack {
                        Image(systemName: "sparkle.magnifyingglass")
                            .foregroundStyle(.blue)
                        Text("ideScan.scanExisting".localized())
                        Spacer()
                        Image(systemName: "chevron.right")
                            .font(.caption)
                            .foregroundStyle(.tertiary)
                    }
                    .padding(.horizontal, 10)
                    .padding(.vertical, 8)
                    .background(
                        RoundedRectangle(cornerRadius: QuotioTheme.Radius.md, style: .continuous)
                            .fill(QuotioTheme.Colors.cardInset(for: colorScheme))
                    )
                    .overlay(
                        RoundedRectangle(cornerRadius: QuotioTheme.Radius.md, style: .continuous)
                            .strokeBorder(QuotioTheme.Colors.sidebarBorder(for: colorScheme), lineWidth: 0.5)
                    )
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .focusEffectDisabled()

                // Add Custom Provider option
                Button {
                    onAddCustomProvider()
                    onDismiss()
                } label: {
                    HStack {
                        Image(systemName: "puzzlepiece.extension")
                            .foregroundStyle(.purple)
                        Text("customProviders.add".localized())
                        Spacer()
                        Image(systemName: "chevron.right")
                            .font(.caption)
                            .foregroundStyle(.tertiary)
                    }
                    .padding(.horizontal, 10)
                    .padding(.vertical, 8)
                    .background(
                        RoundedRectangle(cornerRadius: QuotioTheme.Radius.md, style: .continuous)
                            .fill(QuotioTheme.Colors.cardInset(for: colorScheme))
                    )
                    .overlay(
                        RoundedRectangle(cornerRadius: QuotioTheme.Radius.md, style: .continuous)
                            .strokeBorder(QuotioTheme.Colors.sidebarBorder(for: colorScheme), lineWidth: 0.5)
                    )
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .focusEffectDisabled()
            }
        }
        .padding(16)
        .background(QuotioTheme.Colors.cardBackground(for: colorScheme))
        .frame(width: 320)
    }
}

// MARK: - Provider Button

private struct ProviderButton: View {
    @Environment(\.colorScheme) private var colorScheme
    let provider: AIProvider
    let title: String
    let existingCount: Int  // Number of existing accounts for this provider
    var showsKeyboardFocus = false
    let action: () -> Void

    @State private var isHovered = false
    @FocusState private var isFocused: Bool

    var body: some View {
        Button(action: action) {
            VStack(spacing: 8) {
                ZStack(alignment: .topTrailing) {
                    ProviderIcon(provider: provider, size: 32)

                    // Badge showing existing account count
                    if existingCount > 0 {
                        Text("\(existingCount)")
                            .font(.system(size: 10, weight: .bold))
                            .foregroundStyle(.white)
                            .padding(4)
                            .background(provider.color)
                            .clipShape(Circle())
                            .offset(x: 8, y: -8)
                    }
                }

                Text(title)
                    .font(.caption)
                    .lineLimit(1)
                    .minimumScaleFactor(0.8)
            }
            .frame(width: 80, height: 72)
            .background(
                RoundedRectangle(cornerRadius: QuotioTheme.Radius.md, style: .continuous)
                    .fill(isHovered ? provider.color.opacity(0.14) : QuotioTheme.Colors.cardInset(for: colorScheme))
            )
            .overlay(
                RoundedRectangle(cornerRadius: QuotioTheme.Radius.md, style: .continuous)
                    .strokeBorder(
                        isHovered ? provider.color.opacity(0.35) : QuotioTheme.Colors.sidebarBorder(for: colorScheme),
                        lineWidth: 0.5
                    )
            )
            // 网格样式关闭了系统焦点特效。官方入口保留原生 Button 的键盘激活，
            // 获得焦点时用系统强调色绘制清晰的内边框，避免与悬停提示混淆。
            .overlay {
                if showsKeyboardFocus && isFocused {
                    RoundedRectangle(cornerRadius: QuotioTheme.Radius.md, style: .continuous)
                        .strokeBorder(Color.accentColor, lineWidth: 2)
                        .allowsHitTesting(false)
                        .accessibilityHidden(true)
                }
            }
        }
        .buttonStyle(.gridItem(hoverColor: provider.color.opacity(0.1)))
        .focusEffectDisabled()
        .focused($isFocused)
        .onHover { hovering in
            withAnimation(.easeInOut(duration: 0.15)) {
                isHovered = hovering
            }
        }
    }
}

// MARK: - Preview

#Preview {
    AddProviderPopover(
        providers: AIProvider.allCases.filter { $0.supportsManualAuth },
        existingCounts: [.claude: 2, .antigravity: 1],  // Preview with some existing accounts
        onSelectProvider: { provider in
            print("Selected: \(provider.displayName)")
        },
        onScanIDEs: {
            print("Scan IDEs")
        },
        onAddOfficialOpenAI: {},
        onAddCustomProvider: {
            print("Add Custom Provider")
        },
        onDismiss: {}
    )
}
