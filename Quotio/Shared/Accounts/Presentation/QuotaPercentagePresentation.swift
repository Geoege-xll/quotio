import Foundation

// 仪表盘、账号、菜单栏及偏好汇总共同使用的额度呈现规则。
// 保持未知值与真实零值的区别，不读取设置或触发刷新；原有调用名称和计算结果保持不变。

/// 配额页与仪表盘共用的数值规则：未知值不是零余额，独立金额也不是百分比额度。
/// 纯函数不依赖账号、网络或用户设置，便于用固定上游样例验证所有展示入口的语义。
nonisolated enum QuotaPercentagePresentation {
    static func isKnown(_ value: Double) -> Bool {
        value.isFinite && value >= 0
    }

    static func lowestRemaining(in models: [ModelQuota]) -> Double? {
        models.filter { !$0.isStandaloneMetric && isKnown($0.percentage) }
            .map { min(100, $0.percentage) }.min()
    }

    static func sorted(_ models: [ModelQuota]) -> [ModelQuota] {
        models.sorted {
            let left = isKnown($0.percentage) ? $0.percentage : Double.infinity
            let right = isKnown($1.percentage) ? $1.percentage : Double.infinity
            return left == right ? $0.id < $1.id : left < right
        }
    }

    /// nil 要一直保留到文字和进度条分支，防止未知额度被转换为已用 100%。
    static func displayValue(_ remaining: Double, showUsed: Bool) -> Double? {
        guard isKnown(remaining) else { return nil }
        let clamped = min(100, remaining)
        return showUsed ? 100 - clamped : clamped
    }

    static func text(_ remaining: Double, showUsed: Bool = false) -> String {
        guard let value = displayValue(remaining, showUsed: showUsed) else { return "—" }
        return String(format: "%.0f%%", value)
    }
}
