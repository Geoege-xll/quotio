import Foundation

// 通用账号身份、额度指标与额度快照集中在账号共享模型中，所有提供商、页面和菜单栏复用。
// 本次整声明迁移，保留可选字段、初始化器、Codable 合成结构和未知额度语义。
// Antigravity 分组派生属性及 subscriptionInfo 仍按已有类型工作，不在本批改变缓存协议。

/// Stable identity for one account in the provider quota dictionary.
nonisolated struct QuotaAccountID: Hashable, Sendable {
    let provider: AIProvider
    let accountKey: String
}

// MARK: - Quota Metric Presentation

/// Optional typed value for quota rows that are not plain percentages.
/// Existing snapshots omit this field and continue to render through ModelQuota.percentage.
nonisolated enum QuotaMetricUnit: String, Codable, Sendable, Equatable {
    case usd
    case credits
    case requests
    case searches

    func format(_ value: Double) -> String {
        let locale = LanguageManager.staticLocale
        switch self {
        case .usd:
            return value.formatted(.currency(code: "USD").precision(.fractionLength(0...2)))
        case .credits:
            return String(format: "quota.metric.unit.credits".localizedStatic(), locale: locale, value)
        case .requests:
            return String(format: "quota.metric.unit.requests".localizedStatic(), locale: locale, value)
        case .searches:
            return String(format: "quota.metric.unit.searches".localizedStatic(), locale: locale, value)
        }
    }
}

nonisolated enum QuotaAmountSemantics: String, Codable, Sendable, Equatable {
    case balance
    case spent
}

nonisolated enum QuotaMetricPresentation: Codable, Sendable, Equatable {
    case progress(used: Double, limit: Double, unit: QuotaMetricUnit)
    case amount(value: Double, unit: QuotaMetricUnit, semantics: QuotaAmountSemantics)
    case status(text: String)
}

// MARK: - Models

nonisolated struct ModelQuota: Codable, Identifiable, Sendable {
    let name: String
    let percentage: Double
    let resetTime: String

    /// Typed value for currency/count/status rows. Nil keeps the legacy percentage presentation.
    var presentation: QuotaMetricPresentation?

    // Optional usage details for providers that support it (e.g., Cursor)
    var used: Int?
    var limit: Int?
    var remaining: Int?

    // Optional tooltip message (e.g., Warp bonus userFacingMessage)
    var tooltip: String?

    /// 保留上游名称及明确的额度周期；旧缓存缺少这些可选字段时仍可正常解码。
    var sourceDisplayName: String?
    var antigravityWindow: AntigravityQuotaWindow?
    /// 上游明确提供的完整额度周期长度，供节奏参考使用；nil 表示未知，不由重置倒计时猜测。
    /// 可选字段兼容所有旧缓存与配置，原类型、指标 ID、百分比和初始化调用保持不变。
    var windowSeconds: TimeInterval?
    /// 仅倒计时推算的 resetTime 会随网络延迟漂移；保留原展示，但不能当成精确周期身份或预测依据。
    /// nil 兼容旧缓存，旧缓存没有 windowSeconds 时仍不会启用周期预测。
    var resetTimeIsEstimated: Bool?

    init(
        name: String,
        percentage: Double,
        resetTime: String,
        presentation: QuotaMetricPresentation? = nil,
        used: Int? = nil,
        limit: Int? = nil,
        remaining: Int? = nil,
        tooltip: String? = nil,
        sourceDisplayName: String? = nil,
        antigravityWindow: AntigravityQuotaWindow? = nil,
        windowSeconds: TimeInterval? = nil,
        resetTimeIsEstimated: Bool? = nil
    ) {
        self.name = name
        self.percentage = percentage
        self.resetTime = resetTime
        self.presentation = presentation
        self.used = used
        self.limit = limit
        self.remaining = remaining
        self.tooltip = tooltip
        self.sourceDisplayName = sourceDisplayName
        self.antigravityWindow = antigravityWindow
        self.windowSeconds = windowSeconds
        self.resetTimeIsEstimated = resetTimeIsEstimated
    }

    var id: String { name }

    var usedPercentage: Double {
        100 - percentage
    }

    var formattedPercentage: String {
        if percentage < 0 {
            return "—" // Unknown/unavailable
        }
        if percentage == percentage.rounded() {
            return String(format: "%.0f%%", percentage)
        }
        return String(format: "%.2f%%", percentage)
    }

    /// Formatted usage string like "150/2000" or "150 used"
    var formattedUsage: String? {
        if let presentation {
            switch presentation {
            case .progress(let used, let limit, let unit):
                return unit.format(used) + " / " + unit.format(limit)
            case .amount(let value, let unit, let semantics):
                let key = semantics == .balance ? "quota.metric.balanceValue" : "quota.metric.spentValue"
                return String(format: key.localizedStatic(), unit.format(value))
            case .status(let text):
                return text
            }
        }
        guard let used = used else { return nil }
        if let limit = limit, limit > 0 {
            return "\(used)/\(limit)"
        }
        return "\(used) used"
    }

    var isStandaloneMetric: Bool {
        guard let presentation else { return false }
        switch presentation {
        case .amount, .status: return true
        case .progress: return false
        }
    }

    var modelGroup: AntigravityModelGroup? {
        AntigravityModelGroup.group(for: name)
    }

    var displayName: String {
        if let sourceDisplayName, !sourceDisplayName.isEmpty { return sourceDisplayName }
        switch name {
        // Antigravity Gemini models
        case "gemini-3-pro-high": return "Gemini 3 Pro"
        case "gemini-3-pro": return "Gemini 3 Pro"
        case "gemini-3-flash": return "Gemini 3 Flash"
        case "gemini-3-flash-high": return "Gemini 3 Flash"
        case "gemini-3-pro-image": return "Gemini 3 Image"
        case "gemini-3-flash-image": return "Gemini 3 Image"
        // Antigravity Claude models
        case "claude-sonnet-4-5": return "Claude Sonnet 4.5"
        case "claude-sonnet-4-5-thinking": return "Claude Sonnet 4.5 (Thinking)"
        case "claude-opus-4": return "Claude Opus 4"
        case "claude-opus-4-5": return "Claude Opus 4.5"
        case "claude-opus-4-5-thinking": return "Claude Opus 4.5 (Thinking)"
        case "claude-opus-4-6": return "Claude Opus 4.6"
        case "claude-opus-4-6-thinking": return "Claude Opus 4.6 (Thinking)"
        case "claude-4-sonnet": return "Claude 4 Sonnet"
        case "claude-4-opus": return "Claude 4 Opus"
        // Antigravity quota summary names
        case "antigravity-gemini-session": return "Gemini Session"
        case "antigravity-gemini-weekly": return "Gemini Weekly"
        case "antigravity-claude-gpt-session": return "Claude/GPT Session"
        case "antigravity-claude-gpt-weekly": return "Claude/GPT Weekly"
        // Codex quota names
        case "codex-session": return "Session"
        case "codex-weekly": return "Weekly"
        case "codex-spark": return "Codex Spark"
        case "codex-spark-weekly": return "Codex Spark Weekly"
        case let name where name.hasPrefix("codex-"):
            return name.dropFirst("codex-".count)
                .split(separator: "-")
                .map { $0.prefix(1).uppercased() + $0.dropFirst() }
                .joined(separator: " ")
        // Copilot quota names
        case "copilot-chat": return "Chat"
        case "copilot-completions": return "Completions"
        case "copilot-premium": return "Premium"
        // Cursor quota names
        case "plan-usage": return "Plan Usage"
        case "on-demand": return "On-Demand"
        case "cursor-usage": return "Usage"
        // Claude Code quota names
        case "five-hour-session": return "Session"
        case "seven-day-weekly": return "Weekly"
        case "seven-day-sonnet": return "Sonnet"
        case "seven-day-opus": return "Opus"
        case "extra-usage": return "Extra"
        case "weekly-usage": return "Weekly"
        case "sonnet-only": return "Sonnet"
        // Gemini CLI
        case "gemini-quota": return "Gemini"
        // Trae quota names
        case "trae-usage": return "Usage"
        case "premium-fast": return "Fast Requests"
        case "premium-slow": return "Slow Requests"
        case "advanced-model": return "Advanced"
        case "auto-completion": return "Completions"
        // Windsurf quota names
        case "windsurf-usage": return "Usage"
        // Warp quota names
        case "warp-usage": return "warp.credits.label".localizedStatic()
        // ClinePass quota windows
        case "clinepass-five-hour": return "clinepass.quota.fiveHour".localizedStatic()
        case "clinepass-weekly": return "clinepass.quota.weekly".localizedStatic()
        case "clinepass-monthly": return "clinepass.quota.monthly".localizedStatic()
        // Z.ai / GLM Coding Plan
        case "zai-session": return "quota.metric.session".localizedStatic()
        case "zai-daily": return "quota.metric.daily".localizedStatic()
        case "zai-weekly": return "quota.metric.weekly".localizedStatic()
        case "zai-monthly": return "quota.metric.monthly".localizedStatic()
        case "zai-web-searches": return "quota.metric.webSearches".localizedStatic()
        // Devin
        case "devin-daily": return "quota.metric.daily".localizedStatic()
        case "devin-weekly": return "quota.metric.weekly".localizedStatic()
        case "devin-extra-balance": return "quota.metric.extraBalance".localizedStatic()
        // Grok
        case "grok-weekly": return "quota.metric.weekly".localizedStatic()
        case "grok-extra-usage": return "quota.metric.extraUsage".localizedStatic()
        // Factory Droid
        case "factory-standard-five-hour": return "factory.quota.standardFiveHour".localizedStatic()
        case "factory-standard-weekly": return "factory.quota.standardWeekly".localizedStatic()
        case "factory-standard-monthly": return "factory.quota.standardMonthly".localizedStatic()
        case "factory-core-five-hour": return "factory.quota.coreFiveHour".localizedStatic()
        case "factory-core-weekly": return "factory.quota.coreWeekly".localizedStatic()
        case "factory-core-monthly": return "factory.quota.coreMonthly".localizedStatic()
        case "factory-extra-balance": return "quota.metric.extraBalance".localizedStatic()
        case "factory-billing-mode": return "factory.quota.billingMode".localizedStatic()
        // OpenRouter
        case "openrouter-credits": return "quota.metric.credits".localizedStatic()
        case "openrouter-balance": return "quota.metric.balance".localizedStatic()
        case "openrouter-today": return "quota.metric.today".localizedStatic()
        case "openrouter-week": return "quota.metric.thisWeek".localizedStatic()
        case "openrouter-month": return "quota.metric.thisMonth".localizedStatic()
        case "openrouter-key-limit": return "quota.metric.keyLimit".localizedStatic()
        // Amp
        case "amp-free": return "amp.quota.free".localizedStatic()
        case "amp-agent-usage": return "amp.quota.agent".localizedStatic()
        case "amp-orb-usage": return "amp.quota.orb".localizedStatic()
        case "amp-individual-credits": return "amp.quota.individualCredits".localizedStatic()
        case let name where name.hasPrefix("amp-workspace-"):
            return "amp.quota.workspaceCredits".localizedStatic()
        case let name where name.hasPrefix("warp-bonus-"):
            let index = Int(String(name.dropFirst("warp-bonus-".count))) ?? 0
            return "Bonus \(index + 1)"
        default: return name
        }
    }

    var formattedResetTime: String {
        guard !resetTime.isEmpty else { return "—" }

        // Try parsing with fractional seconds first, then standard format
        let isoFormatterWithFractional = ISO8601DateFormatter()
        isoFormatterWithFractional.formatOptions = [.withInternetDateTime, .withFractionalSeconds]

        let isoFormatterStandard = ISO8601DateFormatter()
        isoFormatterStandard.formatOptions = [.withInternetDateTime]

        guard let date = isoFormatterWithFractional.date(from: resetTime)
              ?? isoFormatterStandard.date(from: resetTime) else {
            return "—"
        }

        let now = Date()
        let interval = date.timeIntervalSince(now)

        if interval <= 0 {
            return "now"
        }

        let totalMinutes = Int(interval / 60)
        let hours = totalMinutes / 60
        let minutes = totalMinutes % 60
        let days = hours / 24
        let remainingHours = hours % 24

        if days > 0 {
            if remainingHours > 0 {
                return "\(days)d \(remainingHours)h"
            }
            return "\(days)d"
        } else if hours > 0 {
            if minutes > 0 {
                return "\(hours)h \(minutes)m"
            }
            return "\(hours)h"
        } else {
            return "\(max(1, minutes))m"
        }
    }
}

nonisolated struct ProviderQuotaData: Codable, Sendable {
    var models: [ModelQuota]
    var lastUpdated: Date
    var isForbidden: Bool
    var planType: String?
    var tokenExpiresAt: Date?  // For Kiro: token expiry time
    var analytics: QuotaAnalytics?
    var accountDisplayName: String?
    /// 监控额度携带查询时的稳定账号身份，防止后续异步归并把同邮箱换号前的额度归给新账号。
    /// 仅记录账号标识，不包含令牌；可选字段兼容已有快照，也允许旧文件名变化后迁移缓存。
    var monitorAccountIdentity: String? = nil
    /// CPA 配额响应携带同一账号查询出的订阅信息，供发布层同步订阅卡片；旧快照缺失时保持 nil。
    var subscriptionInfo: SubscriptionInfo?

    init(
        models: [ModelQuota] = [],
        lastUpdated: Date = Date(),
        isForbidden: Bool = false,
        planType: String? = nil,
        tokenExpiresAt: Date? = nil,
        analytics: QuotaAnalytics? = nil,
        accountDisplayName: String? = nil,
        subscriptionInfo: SubscriptionInfo? = nil
    ) {
        self.models = models
        self.lastUpdated = lastUpdated
        self.isForbidden = isForbidden
        self.planType = planType
        self.tokenExpiresAt = tokenExpiresAt
        self.analytics = analytics
        self.accountDisplayName = accountDisplayName
        self.subscriptionInfo = subscriptionInfo
    }

    /// Format token expiry time in user's local timezone
    var formattedTokenExpiry: String? {
        guard let expiresAt = tokenExpiresAt else { return nil }

        let now = Date()
        let interval = expiresAt.timeIntervalSince(now)

        // If expired
        if interval <= 0 {
            return "Expired"
        }

        // Format as local time
        let formatter = DateFormatter()
        formatter.dateFormat = "HH:mm"
        formatter.timeZone = TimeZone.current
        return "Token expires \(formatter.string(from: expiresAt))"
    }

    var planDisplayName: String? {
        guard let plan = planType?.lowercased() else { return nil }
        switch plan {
        case "guest": return "Guest"
        case "free": return "Free"
        case "go": return "Go"
        case "plus": return "Plus"
        case "pro": return "Pro"
        case "free_workspace": return "Free Workspace"
        case "team": return "Team"
        case "business": return "Business"
        case "education": return "Education"
        case "quorum": return "Quorum"
        case "k12": return "K-12"
        case "enterprise": return "Enterprise"
        case "edu": return "Edu"
        default: return planType?.capitalized
        }
    }

    var groupedModels: [GroupedModelQuota] {
        var grouped: [AntigravityModelGroup: [ModelQuota]] = [:]

        for model in models {
            guard let group = model.modelGroup else { continue }
            grouped[group, default: []].append(model)
        }

        return AntigravityModelGroup.allCases.compactMap { group in
            guard let models = grouped[group], !models.isEmpty else { return nil }
            return GroupedModelQuota(group: group, models: models)
        }
    }

    var hasGroupedModels: Bool {
        models.contains { $0.modelGroup != nil }
    }
}
