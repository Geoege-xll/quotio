import Foundation

/// 仅记录接口明确声明的周期，不根据套餐、模型名称或距离重置的时长推测。
nonisolated enum AntigravityQuotaWindow: String, Codable, Sendable {
    case session
    case weekly
}

/// 配额页和状态栏共用同一份明细。每个上游模型/额度桶独立展示，
/// 防止不同额度池被平均、旧版本名称漏匹配，以及百分比与重置时间错配。
nonisolated struct AntigravityDisplayGroup: Identifiable, Sendable {
    let model: ModelQuota

    var id: String { model.id }
    var name: String {
        model.sourceDisplayName ?? (Self.window(for: model) == nil ? model.name : model.displayName)
    }
    var percentage: Double { model.percentage }
    var models: [ModelQuota] { [model] }
    var resetTime: String? { model.resetTime.isEmpty ? nil : model.resetTime }

    static func make(from models: [ModelQuota]) -> [Self] {
        models.sorted {
            // 已知额度从低到高排列；未知额度放在末尾，不冒充耗尽状态。
            let left = $0.percentage >= 0 ? $0.percentage : Double.infinity
            let right = $1.percentage >= 0 ? $1.percentage : Double.infinity
            return left == right ? $0.name < $1.name : left < right
        }.map { Self(model: $0) }
    }

    /// 状态栏的单值表示当前最紧张的额度，不把独立限额平均成虚假的总余额。
    static func lowestRemaining(in models: [ModelQuota]) -> Double {
        models.map(\.percentage).filter { $0.isFinite && $0 >= 0 }.min() ?? -1
    }

    static func window(for model: ModelQuota) -> AntigravityQuotaWindow? {
        if let window = model.antigravityWindow { return window }
        // 兼容旧版本已保存的四个明确周期名称，不对任意字符串做后缀猜测。
        switch model.name {
        case "antigravity-gemini-session", "antigravity-claude-gpt-session": return .session
        case "antigravity-gemini-weekly", "antigravity-claude-gpt-weekly": return .weekly
        default: return nil
        }
    }
}
