//
//  MenuAccountCardView.swift
//  Quotio
//

import AppKit
import SwiftUI

/// 菜单栏账号卡片与 Factory Droid 小节标题。
/// 账号、隐私、展开状态及回调继续沿用原声明；只开放 builder 必需的卡片类型，局部标题仍私有。
// MARK: Account Card View

struct MenuAccountCardView: View {
    @Environment(QuotaViewModel.self) private var viewModel
    let accountKey: String
    let email: String
    let data: ProviderQuotaData
    let provider: AIProvider
    let subscriptionInfo: SubscriptionInfo?
    let isActiveInIDE: Bool
    let onUseAccount: (() -> Void)?
    
    /// 默认仍使用原共享偏好；装配器传入同一 ViewModel 的只读设置，便于隔离回归且不复制配置。
    var settings: MenuBarSettingsManager = .shared
    @State private var isHovered = false
    @State private var isUseHovered = false
    @State private var isUsingAccount = false

    private var accountID: QuotaAccountID {
        QuotaAccountID(provider: provider, accountKey: accountKey)
    }
    
    private var displayEmail: String {
        email.masked(if: settings.hideSensitiveInfo)
    }
    
    // Modern Tier Badge Config
    private var tierConfig: (name: String, bgColor: Color, textColor: Color)? {
        if let info = subscriptionInfo {
            let tierId = info.tierId.lowercased()
            let tierName = info.tierDisplayName.lowercased()
            
            if tierId.contains("ultra") || tierName.contains("ultra") {
                return ("Ultra", .orange.opacity(0.15), .orange)
            }
            if tierId.contains("pro") || tierName.contains("pro") {
                return ("Pro", .blue.opacity(0.15), .blue)
            }
            if tierId.contains("standard") || tierId.contains("free") ||
               tierName.contains("standard") || tierName.contains("free") {
                return ("Free", .secondary.opacity(0.1), .secondary)
            }
            return (info.tierDisplayName, .secondary.opacity(0.1), .secondary)
        }
        
        if provider == .codex, let planName = codexPlanDisplayName(data.planType) {
            let config = planConfig(for: planName)
            return (planName, config.bgColor, config.textColor)
        }

        guard let planName = data.planDisplayName else { return nil }
        return planConfig(for: planName)
    }

    private func codexPlanDisplayName(_ raw: String?) -> String? {
        guard let trimmed = raw?.trimmingCharacters(in: .whitespacesAndNewlines), !trimmed.isEmpty else {
            return nil
        }

        let exact = [
            "pro": "Pro 20x",
            "prolite": "Pro 5x",
            "pro_lite": "Pro 5x",
            "pro-lite": "Pro 5x",
            "pro lite": "Pro 5x"
        ]
        if let value = exact[trimmed.lowercased()] {
            return value
        }

        let cleaned = trimmed
            .replacingOccurrences(of: #"(?i)\b(claude|codex|account|plan)\b"#, with: " ", options: .regularExpression)
            .replacingOccurrences(of: "_", with: " ")
            .replacingOccurrences(of: "-", with: " ")
            .split(separator: " ")
            .joined(separator: " ")
        if let value = exact[cleaned.lowercased()] {
            return value
        }

        let display = cleaned.split(separator: " ").map { word -> String in
            let lower = word.lowercased()
            if lower == "cbp" || lower == "k12" { return lower.uppercased() }
            if word == word.uppercased(), word.contains(where: { $0.isLetter }) { return String(word) }
            return word.prefix(1).uppercased() + word.dropFirst()
        }.joined(separator: " ")
        return display.isEmpty ? trimmed : display
    }
    
    private func planConfig(for planName: String) -> (name: String, bgColor: Color, textColor: Color) {
        let lowercased = planName.lowercased()
        
        if lowercased.contains("ultra") {
            return ("Ultra", .orange.opacity(0.15), .orange)
        }
        if lowercased.contains("pro") {
            return ("Pro", .blue.opacity(0.15), .blue)
        }
        if lowercased.contains("plus") {
            return ("Plus", .blue.opacity(0.15), .blue)
        }
        if lowercased.contains("team") {
            return ("Team", .orange.opacity(0.15), .orange)
        }
        if lowercased.contains("enterprise") {
            return ("Enterprise", .red.opacity(0.15), .red)
        }
        if lowercased.contains("business") {
            return ("Business", .red.opacity(0.15), .red)
        }
        if lowercased.contains("free") || lowercased.contains("standard") {
            return ("Free", .secondary.opacity(0.1), .secondary)
        }
        
        return (planName, .secondary.opacity(0.1), .secondary)
    }
    
    private var isAntigravity: Bool {
        provider == .antigravity && !data.models.isEmpty
    }
    
    /// 页面与状态栏共用完整明细，百分比及重置时间均来自同一个上游额度桶。
    private var antigravityGroups: [AntigravityDisplayGroup] {
        guard isAntigravity else { return [] }
        return AntigravityDisplayGroup.make(from: data.models)
    }
    
    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            headerSection
            
            quotaContentSection
            
            footerSection
        }
        // 收紧卡片内部及卡片间距，保留条形／环形／卡片三种原额度布局。
        .padding(.horizontal, 10)
        .padding(.vertical, 8)
        .background(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .fill(isHovered ? Color.secondary.opacity(0.08) : Color.secondary.opacity(0.04))
        )
        .padding(.horizontal, 8)
        .padding(.vertical, 3)
        .accessibilityIdentifier("menubar.account.card")
        .onHover { isHovered = $0 }
    }
    
    // MARK: - Header
    
    private var headerSection: some View {
        HStack(alignment: .center, spacing: 6) {
            // Provider Icon
            ProviderIconMono(provider: provider, size: 16)
                .foregroundStyle(.secondary)
                .opacity(0.8)
            
            // Email
            Text(displayEmail)
                .font(.system(size: 13, weight: .medium, design: .rounded))
                .foregroundStyle(.primary)
                .lineLimit(1)
                // 中间省略保留账号前缀和域名；提示同样遵守隐私遮罩，不暴露完整邮箱。
                .truncationMode(.middle)
                .frame(maxWidth: .infinity, alignment: .leading)
                .help(displayEmail)
            
            // Tier Badge
            if let config = tierConfig {
                Text(config.name)
                    .font(.system(size: 10, weight: .semibold, design: .rounded))
                    .foregroundStyle(config.textColor)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 3)
                    .background(config.bgColor)
                    .clipShape(Capsule())
            }
            
            Spacer(minLength: 0)

            Button {
                Task { await viewModel.refreshQuota(for: accountID) }
            } label: {
                if viewModel.isRefreshing(account: accountID) {
                    ProgressView()
                        .controlSize(.mini)
                        .frame(width: 20, height: 20)
                } else {
                    Image(systemName: "arrow.clockwise")
                        .font(.system(size: 10, weight: .semibold))
                        .foregroundStyle(.secondary)
                        .frame(width: 20, height: 20)
                }
            }
            .buttonStyle(.plain)
            .disabled(
                viewModel.isRefreshBlocked(for: accountID)
                    || !viewModel.supportsScopedRefresh(for: provider)
            )
            .help("action.refreshQuota".localized())
            .accessibilityIdentifier("menubar.account.refresh")
            
            Image(systemName: "chevron.right")
                .font(.system(size: 9, weight: .semibold))
                .foregroundStyle(.tertiary)
                .accessibilityHidden(true)
        }
    }

    @ViewBuilder
    private var ideControl: some View {
        // 原 IDE 活动徽章和切换操作保留在卡片底部，与更新时间同行。
        if isActiveInIDE {
            Text("antigravity.active".localized())
                .font(.system(size: 10, weight: .medium, design: .rounded))
                .foregroundStyle(.green)
                .padding(.horizontal, 8)
                .padding(.vertical, 3)
                .background(Color.green.opacity(0.12))
                .overlay(
                    Capsule()
                        .strokeBorder(Color.green.opacity(0.25), lineWidth: 1)
                )
                .clipShape(Capsule())
        } else if let onUse = onUseAccount {
            Button {
                isUsingAccount = true
                Task { @MainActor in
                    onUse()
                    try? await Task.sleep(nanoseconds: 650_000_000)
                    isUsingAccount = false
                }
            } label: {
                HStack(spacing: 6) {
                    if isUsingAccount {
                        ProgressView()
                            .controlSize(.mini)
                    }
                    Text("antigravity.useInIDE".localized() + " " + "→".localized())
                        .font(.system(size: 10, weight: .semibold, design: .rounded))
                }
                .foregroundStyle(.secondary)
                .padding(.horizontal, 8)
                .padding(.vertical, 3)
                .background(isUseHovered ? Color.secondary.opacity(0.12) : Color.secondary.opacity(0.06))
                .overlay(
                    Capsule()
                        .strokeBorder(Color.secondary.opacity(isUseHovered ? 0.45 : 0.25), lineWidth: 1)
                )
                .clipShape(Capsule())
            }
            .buttonStyle(.plain)
            .disabled(isUsingAccount)
            .onHover { isUseHovered = $0 }
            .accessibilityIdentifier("menubar.account.useIDE")
        }
    }

    // MARK: - Quota Content
    
    private var quotaContentSection: some View {
        let isCardStyle = displayStyle == .card
        let models: [ModelBadgeData] = {
            if isAntigravity {
                return antigravityGroups.map { ModelBadgeData(name: $0.name, percentage: $0.percentage, resetTime: $0.resetTime, sourceID: $0.id) }
            } else {
                let meterModels = data.models.filter { !$0.isStandaloneMetric }.map {
                    ModelBadgeData(name: $0.displayName, percentage: $0.percentage, resetTime: $0.resetTime, sourceID: $0.id)
                }
                guard isCardStyle else { return meterModels }
                let standaloneModels = data.models.filter(\.isStandaloneMetric).map {
                    ModelBadgeData(name: $0.displayName, percentage: $0.percentage, resetTime: $0.resetTime, usage: $0.formattedUsage, sourceID: $0.id)
                }
                return meterModels + standaloneModels
            }
        }()
        let standaloneModels = isAntigravity || isCardStyle ? [] : data.models.filter(\.isStandaloneMetric)
        let factorySections = provider == .factoryDroid
            ? FactoryDroidQuotaSection.sections(from: data.models.filter { !$0.isStandaloneMetric })
            : []
        
        return VStack(spacing: 6) {
            if models.isEmpty && standaloneModels.isEmpty {
                Text("dashboard.noQuotaData".localized())
                    .font(.caption)
                    .foregroundStyle(.tertiary)
                    .frame(maxWidth: .infinity, alignment: .center)
                    .padding(.vertical, 8)
            } else if !factorySections.isEmpty {
                ForEach(factorySections) { section in
                    VStack(alignment: .leading, spacing: 6) {
                        FactoryDroidMenuSectionHeader(title: section.title)
                        quotaLayout(models: section.models.map {
                            ModelBadgeData(name: $0.displayName, percentage: $0.percentage, resetTime: $0.resetTime, sourceID: $0.id)
                        })
                    }
                }
            } else if !models.isEmpty {
                quotaLayout(models: models)
            }

            ForEach(standaloneModels) { model in
                HStack(spacing: 8) {
                    Text(model.displayName)
                        .font(.system(size: 10, weight: .medium, design: .rounded))
                        .foregroundStyle(.secondary)
                    Spacer()
                    Text(model.formattedUsage ?? "—")
                        .font(.system(size: 10, weight: .semibold, design: .monospaced))
                        .foregroundStyle(.primary)
                }
                .padding(.horizontal, 8)
                .padding(.vertical, 5)
                .menuNativeTooltip(model.tooltip ?? "")
            }
        }
    }

    @ViewBuilder
    private func quotaLayout(models: [ModelBadgeData]) -> some View {
        switch settings.quotaDisplayStyle {
        case .lowestBar:
            LowestBarLayout(models: models, settings: settings)
        case .ring:
            RingGridLayout(models: models, settings: settings)
        case .card:
            CardGridLayout(models: models, settings: settings)
        }
    }
    
    // MARK: - Footer

    private var footerSection: some View {
        HStack(spacing: 6) {
            ideControl
            Spacer(minLength: 4)

            // Last Update
            Text(data.lastUpdated.formatted(.relative(presentation: .named)))
                .font(.system(size: 9, design: .rounded))
                .foregroundStyle(.secondary)
                .lineLimit(1)
        }
    }
    
    private var displayStyle: QuotaDisplayStyle { settings.quotaDisplayStyle }
    
    private var primaryResetModel: ModelQuota? {
        let formatter = ISO8601DateFormatter()
        let now = Date()
        
        let validModels = data.models.filter { model in
            guard let date = formatter.date(from: model.resetTime) else { return false }
            return date > now
        }
        
        return validModels.sorted { m1, m2 in
            if abs(m1.percentage - m2.percentage) > 0.1 {
                return m1.percentage < m2.percentage
            }
            let d1 = formatter.date(from: m1.resetTime) ?? Date.distantFuture
            let d2 = formatter.date(from: m2.resetTime) ?? Date.distantFuture
            return d1 < d2
        }.first
    }
    
    private func formatLocalTime(_ isoString: String) -> String {
        // Try parsing with fractional seconds first, then standard format
        let isoFormatterWithFractional = ISO8601DateFormatter()
        isoFormatterWithFractional.formatOptions = [.withInternetDateTime, .withFractionalSeconds]

        let isoFormatterStandard = ISO8601DateFormatter()
        isoFormatterStandard.formatOptions = [.withInternetDateTime]

        guard let date = isoFormatterWithFractional.date(from: isoString)
              ?? isoFormatterStandard.date(from: isoString) else { return "" }

        let formatter = DateFormatter()
        formatter.dateStyle = .medium
        formatter.timeStyle = .short
        return formatter.string(from: date)
    }
}

private struct FactoryDroidMenuSectionHeader: View {
    let title: String

    var body: some View {
        HStack(spacing: 8) {
            Text(title)
                .font(.system(size: 9, weight: .semibold, design: .rounded))
                .foregroundStyle(.secondary)
            Rectangle()
                .fill(Color.primary.opacity(0.08))
                .frame(height: 1)
        }
    }
}
