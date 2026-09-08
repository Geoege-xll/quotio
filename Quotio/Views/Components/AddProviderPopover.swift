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

            // Provider grid
            LazyVGrid(columns: columns, spacing: 12) {
                ForEach(providers) { provider in
                    ProviderButton(
                        provider: provider,
                        existingCount: existingCounts[provider] ?? 0
                    ) {
                        onSelectProvider(provider)
                        onDismiss()
                    }
                }
            }

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
        .focusEffectDisabled()
    }
}

// MARK: - Provider Button

private struct ProviderButton: View {
    @Environment(\.colorScheme) private var colorScheme
    let provider: AIProvider
    let existingCount: Int  // Number of existing accounts for this provider
    let action: () -> Void

    @State private var isHovered = false

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

                Text(provider.displayName)
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
        }
        .buttonStyle(.gridItem(hoverColor: provider.color.opacity(0.1)))
        .focusEffectDisabled()
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
        onAddCustomProvider: {
            print("Add Custom Provider")
        },
        onDismiss: {}
    )
}
