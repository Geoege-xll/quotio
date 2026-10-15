//
//  MenuBarSettingsManager+QuotaSummary.swift
//  Quotio
//

import Foundation

// 额度摘要算法独立成扩展文件，便于查找跨账号页、仪表盘和菜单栏共用的计算入口。
// 本扩展继续读取同一个 MenuBarSettingsManager 的既有偏好，不引入状态、缓存或新管理器。
// 会话/额外用量选择、模型最低值或平均值、Antigravity 独立额度池与未知值处理均保持原算法。

// MARK: - Usage Calculation Helpers

extension MenuBarSettingsManager {
    /// 配额页与菜单栏共用的账号摘要。金额、积分等独立指标不能混入百分比聚合，
    /// 非法值保持未知；Antigravity 的独立额度池始终使用最低剩余量，不做平均。
    func quotaSummaryPercentage(for provider: AIProvider, models: [ModelQuota]) -> Double {
        let meters = models.filter { !$0.isStandaloneMetric }
        if provider == .antigravity {
            return QuotaPercentagePresentation.lowestRemaining(in: meters) ?? -1
        }
        return totalUsagePercent(models: meters.map {
            (name: $0.name, percentage: QuotaPercentagePresentation.isKnown($0.percentage)
                ? min(100, $0.percentage) : -1)
        })
    }

    /// Compute total usage percentage using session/extra logic
    /// Treats extra-usage, codex-extra, on-demand as extra models; all others as session
    func totalUsagePercent(models: [(name: String, percentage: Double)]) -> Double {
        let extraModelNames: Set<String> = ["extra-usage", "codex-extra", "on-demand"]
        
        var sessionPercentages: [Double] = []
        var extraPercentages: [Double] = []
        
        for model in models {
            if extraModelNames.contains(model.name) {
                extraPercentages.append(model.percentage)
            } else {
                sessionPercentages.append(model.percentage)
            }
        }
        
        let sessionRemaining = aggregateModelPercentages(sessionPercentages)
        let extraRemaining = aggregateModelPercentages(extraPercentages)
        
        let hasExtraModels = !extraPercentages.isEmpty
        
        switch totalUsageMode {
        case .sessionOnly:
            if sessionRemaining >= 0 {
                return sessionRemaining
            }
            if hasExtraModels {
                return extraRemaining
            }
            return -1
            
        case .combined:
            let session = sessionRemaining >= 0 ? sessionRemaining : -1
            let extra = extraRemaining >= 0 ? extraRemaining : -1
            
            if session < 0 && extra < 0 {
                return -1
            }
            if session < 0 {
                return extra
            }
            if extra < 0 {
                return session
            }
            return max(session, extra)
        }
    }
    
    func calculateTotalUsagePercent(sessionPercent: Double?, extraPercent: Double?) -> Double {
        switch totalUsageMode {
        case .sessionOnly:
            if let session = sessionPercent {
                return session
            }
            return extraPercent ?? -1
            
        case .combined:
            let session = sessionPercent ?? -1
            let extra = extraPercent ?? -1
            
            if session < 0 && extra < 0 {
                return -1
            }
            if session < 0 {
                return extra
            }
            if extra < 0 {
                return session
            }
            return max(session, extra)
        }
    }
    
    func aggregateModelPercentages(_ percentages: [Double]) -> Double {
        let validPercentages = percentages.filter { $0 >= 0 }
        guard !validPercentages.isEmpty else { return -1 }
        
        switch modelAggregationMode {
        case .lowest:
            return validPercentages.min() ?? -1
        case .average:
            return validPercentages.reduce(0, +) / Double(validPercentages.count)
        }
    }
}

