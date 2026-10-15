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
    
    /// Convert a remaining percentage to the display value based on mode.
    /// A negative input is the "no data" sentinel and is propagated as -1 so it can
    /// never surface as a fake percentage (e.g. 100 - (-1) = 101%). Valid input is
    /// clamped to 0-100 before conversion.
    func displayValue(from remainingPercent: Double) -> Double {
        guard remainingPercent >= 0 else { return -1 }
        let clamped = min(100, max(0, remainingPercent))
        switch self {
        case .used: return 100 - clamped
        case .remaining: return clamped
        }
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

