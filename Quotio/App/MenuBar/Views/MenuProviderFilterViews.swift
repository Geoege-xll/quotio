//
//  MenuProviderFilterViews.swift
//  Quotio
//

import AppKit
import SwiftUI

/// 菜单栏提供商标题与筛选按钮。
/// 继续绑定原 StatusBarProviderFilterController；仅跨文件调用的分区和选择器开放模块内入口。
/// 按钮及 AIProvider 短名称扩展留在同文件内私有，筛选行为不随目录拆分而改变。
// MARK: - Provider Section Header

struct MenuProviderSectionHeader: View {
    @Environment(QuotaViewModel.self) private var viewModel
    let provider: AIProvider

    var body: some View {
        HStack(spacing: 6) {
            ProviderIconMono(provider: provider, size: 14)
            Text(provider.displayName)
                .font(.system(size: 11, weight: .semibold, design: .rounded))
                .foregroundStyle(.secondary)
            Spacer()

            Button {
                Task { await viewModel.refreshQuota(for: provider) }
            } label: {
                if viewModel.refreshingProviders.contains(provider) {
                    ProgressView()
                        .controlSize(.mini)
                        .frame(width: 18, height: 18)
                } else {
                    Image(systemName: "arrow.clockwise")
                        .font(.system(size: 10, weight: .semibold))
                        .frame(width: 18, height: 18)
                }
            }
            .buttonStyle(.plain)
            .disabled(
                viewModel.isRefreshing(provider: provider)
                    || !viewModel.supportsScopedRefresh(for: provider)
            )
            .help("action.refreshQuota".localized())
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 4)
    }
}

// MARK: - Provider Picker View (separate from accounts list)

struct MenuProviderPickerView: View {
    let providers: [AIProvider]
    let controller: StatusBarProviderFilterController
    
    var body: some View {
        // Wrap providers in a flexible layout
        FlowLayout(spacing: 6) {
            AllProviderFilterButton(isSelected: controller.selectedProvider == nil) {
                controller.select(nil)
            }

            ForEach(providers) { provider in
                ProviderFilterButton(
                    provider: provider,
                    isSelected: controller.selectedProvider == provider
                ) {
                    controller.select(provider)
                }
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
    }
}

// MARK: All Provider Filter Button

private struct AllProviderFilterButton: View {
    let isSelected: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 6) {
                Image(systemName: "square.grid.2x2")
                    .font(.system(size: 12, weight: .semibold))
                    .frame(width: 14, height: 14)
                    .opacity(isSelected ? 1.0 : 0.7)

                Text("menubar.providers.all".localized())
                    .font(.system(size: 11, weight: isSelected ? .semibold : .medium, design: .rounded))
            }
            .foregroundStyle(isSelected ? .primary : .secondary)
            .padding(.horizontal, 10)
            .padding(.vertical, 6)
            .background(
                Capsule()
                    .fill(isSelected ? Color.accentColor.opacity(0.1) : Color.secondary.opacity(0.05))
            )
            .overlay(
                Capsule()
                    .strokeBorder(isSelected ? Color.accentColor.opacity(0.3) : Color.clear, lineWidth: 1)
            )
        }
        .buttonStyle(.plain)
    }
}

// MARK: Provider Filter Button

private struct ProviderFilterButton: View {
    let provider: AIProvider
    let isSelected: Bool
    let action: () -> Void
    
    var body: some View {
        Button(action: action) {
            HStack(spacing: 6) {
                ProviderIconMono(provider: provider, size: 14)
                    .opacity(isSelected ? 1.0 : 0.7)
                
                Text(provider.shortName)
                    .font(.system(size: 11, weight: isSelected ? .semibold : .medium, design: .rounded))
            }
            .foregroundStyle(isSelected ? .primary : .secondary)
            .padding(.horizontal, 10)
            .padding(.vertical, 6)
            .background(
                Capsule()
                    .fill(isSelected ? Color.accentColor.opacity(0.1) : Color.secondary.opacity(0.05))
            )
            .overlay(
                Capsule()
                    .strokeBorder(isSelected ? Color.accentColor.opacity(0.3) : Color.clear, lineWidth: 1)
            )
        }
        .buttonStyle(.plain)
    }
}

// MARK: - AIProvider Extension

private extension AIProvider {
    var shortName: String {
        switch self {
        case .claude: return "Claude"
        case .codex: return "Codex"
        case .cursor: return "Cursor"
        case .copilot: return "Copilot"
        case .trae: return "Trae"
        case .antigravity: return "Antigravity"
        case .qwen: return "Qwen"
        case .iflow: return "iFlow"
        case .vertex: return "Vertex"
        case .kiro: return "Kiro"
        case .factoryDroid: return "Factory Droid"
        case .devin: return "Devin"
        case .grok: return "Grok"
        case .openRouter: return "OpenRouter"
        case .amp: return "Amp"
        case .glm: return "Z.ai"
        case .warp: return "Warp"
        case .clinePass: return "ClinePass"
        }
    }
}
