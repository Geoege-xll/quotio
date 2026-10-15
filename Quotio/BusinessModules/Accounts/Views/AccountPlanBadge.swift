import SwiftUI

/// 账号身份行使用的套餐徽章入口，复用原额度页的完整套餐优先级和显示规则。
/// 数据继续由父视图传入，本文件不查询套餐、不持有账号状态，也不改变已有套餐名称。
struct AccountPlanBadge: View {
    let quotaData: ProviderQuotaData?
    let subscriptionInfo: SubscriptionInfo?

    var body: some View {
        if let subscriptionInfo {
            SubscriptionBadgeV2(info: subscriptionInfo)
        } else if let name = quotaData?.planDisplayName {
            PlanBadgeV2Compact(planName: name)
        }
    }
}

/// 配额卡片与账号身份行共同使用的紧凑套餐徽章。
/// 仅因原有两处调用现在分处不同文件而使用模块内可见性；匹配顺序、颜色与布局保持原样。
struct PlanBadgeV2Compact: View {
    let planName: String

    private var tierConfig: (name: String, color: Color) {
        let lowercased = planName.lowercased()

        // Check for Pro variants
        if lowercased.contains("pro") {
            return ("Pro", .purple)
        }

        // Check for Plus
        if lowercased.contains("plus") {
            return ("Plus", .blue)
        }

        // Check for Team
        if lowercased.contains("team") {
            return ("Team", .orange)
        }

        // Check for Enterprise
        if lowercased.contains("enterprise") {
            return ("Enterprise", .red)
        }

        // Free/Standard
        if lowercased.contains("free") || lowercased.contains("standard") {
            return ("Free", .secondary)
        }

        // Default: use display name
        let displayName = planName
            .replacingOccurrences(of: "_", with: " ")
            .split(separator: " ")
            .map { $0.prefix(1).uppercased() + $0.dropFirst().lowercased() }
            .joined(separator: " ")
        return (displayName, .secondary)
    }

    var body: some View {
        Text(tierConfig.name)
            .font(.caption2)
            .fontWeight(.medium)
            .foregroundStyle(tierConfig.color)
            .padding(.horizontal, 6)
            .padding(.vertical, 2)
            .background(tierConfig.color.opacity(0.12))
            .clipShape(Capsule())
    }
}

/// Antigravity 订阅徽章，继续优先采用接口返回的订阅层级。
/// 与紧凑套餐徽章一样供原有卡片跨文件调用，不扩大内部 tierConfig 等实现细节的可见性。
struct SubscriptionBadgeV2: View {
    let info: SubscriptionInfo

    private var tierConfig: (name: String, color: Color) {
        let tierId = info.tierId.lowercased()
        let tierName = info.tierDisplayName.lowercased()

        // Check for Ultra tier (highest priority)
        if tierId.contains("ultra") || tierName.contains("ultra") {
            return ("Ultra", .orange)
        }

        // Check for Pro tier
        if tierId.contains("pro") || tierName.contains("pro") {
            return ("Pro", .purple)
        }

        // Check for Free/Standard tier
        if tierId.contains("standard") || tierId.contains("free") ||
           tierName.contains("standard") || tierName.contains("free") {
            return ("Free", .secondary)
        }

        // Fallback: use the display name from API
        return (info.tierDisplayName, .secondary)
    }

    var body: some View {
        Text(tierConfig.name)
            .font(.caption2)
            .fontWeight(.medium)
            .foregroundStyle(tierConfig.color)
            .padding(.horizontal, 6)
            .padding(.vertical, 2)
            .background(tierConfig.color.opacity(0.12))
            .clipShape(Capsule())
    }
}
