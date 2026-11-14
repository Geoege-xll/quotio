//
//  QuotaDisplayPreferences.swift
//  Quotio
//

import Foundation

// 这里只声明额度展示与聚合选项，供账号页、仪表盘、菜单栏及设置页面共享，不持有额外状态。
// 各枚举名称、Codable 原始值和本地化键原样保留，确保现有偏好及历史配置仍可直接读取。
// 已用/剩余转换和未知额度哨兵规则保持原实现；真正的偏好存储仍由 MenuBarSettingsManager 统一负责。

// MARK: - Quota Display Mode

/// Display mode for quota percentage (used vs remaining)
enum QuotaDisplayMode: String, Codable, CaseIterable, Identifiable {
    case used = "used"           // Show percentage used (e.g., "75% used")
    case remaining = "remaining" // Show percentage remaining (e.g., "25% left")
    
    var id: String { rawValue }
    
    var localizationKey: String {
        switch self {
        case .used: return "settings.quota.displayMode.used"
        case .remaining: return "settings.quota.displayMode.remaining"
        }
    }
    
    /// 将剩余百分比按当前模式（已用/剩余）转换为展示数值。
    /// 负数表示未知/无数据哨兵，继续传递 -1 避免产生虚假百分比。
    /// 有效数值限制在 0...100 并采用向零取整截断（.towardZero），确保 100 - remaining 与 remaining 之和精确等于 100。
    func displayValue(from remainingPercent: Double) -> Double {
        guard remainingPercent >= 0 else { return -1 }
        let remaining = min(100, max(0, remainingPercent)).rounded(.towardZero)
        return self == .used ? 100 - remaining : remaining
    }
    
    var suffixKey: String {
        switch self {
        case .used: return "settings.quota.used"
        case .remaining: return "settings.quota.left"
        }
    }
}

// MARK: - Quota Display Style

/// Visual style for quota display in the main UI
enum QuotaDisplayStyle: String, Codable, CaseIterable, Identifiable {
    case card = "card"           // Default card with progress bar
    case lowestBar = "lowestBar" // Compact: lowest % bar, others text
    case ring = "ring"           // Circular progress rings

    var id: String { rawValue }

    var localizationKey: String {
        switch self {
        case .card: return "settings.quota.style.card"
        case .lowestBar: return "settings.quota.style.lowestBar"
        case .ring: return "settings.quota.style.ring"
        }
    }

    var iconName: String {
        switch self {
        case .card: return "rectangle.portrait"
        case .lowestBar: return "chart.bar.fill"
        case .ring: return "circle.dotted"
        }
    }
}

// MARK: - Total Usage Calculation Mode

/// Mode for calculating total usage indicators (session vs extra)
enum TotalUsageMode: String, CaseIterable, Identifiable, Codable {
    case sessionOnly = "sessionOnly"
    case combined = "combined"
    
    var id: String { rawValue }
    
    var localizationKey: String {
        switch self {
        case .sessionOnly: return "settings.usageDisplay.totalMode.sessionOnly"
        case .combined: return "settings.usageDisplay.totalMode.combined"
        }
    }
}

// MARK: - Model Aggregation Mode

/// Mode for aggregating multi-model provider quotas
enum ModelAggregationMode: String, CaseIterable, Identifiable, Codable {
    case lowest = "lowest"
    case average = "average"
    
    var id: String { rawValue }
    
    var localizationKey: String {
        switch self {
        case .lowest: return "settings.usageDisplay.modelAggregation.lowest"
        case .average: return "settings.usageDisplay.modelAggregation.average"
        }
    }
}

