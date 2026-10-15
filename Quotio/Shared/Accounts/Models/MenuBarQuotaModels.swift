//
//  MenuBarQuotaModels.swift
//  Quotio
//

import Foundation
import SwiftUI

// 菜单栏选中账号、双行额度指标和展示项是账号能力的公共数据契约，在此集中声明。
// 迁移不改变 Codable 结构、账号身份键、提供商别名、指标配对及最低额度的选择算法；
// nonisolated / Sendable 标注与原有 SwiftUI Color 展示属性均保留，避免改变并发和展示语义。

// MARK: - Menu Bar Quota Item

/// Represents a single item selected for menu bar display
struct MenuBarQuotaItem: Codable, Identifiable, Hashable {
    let provider: String      // AIProvider.rawValue
    let accountKey: String    // email or account identifier
    
    var id: String { "\(provider)_\(accountKey)" }
    
    /// Get the AIProvider enum value
    var aiProvider: AIProvider? {
        // Handle "copilot" alias
        if provider == "copilot" {
            return .copilot
        }
        return AIProvider(rawValue: provider)
    }
    
    /// Short display symbol for the provider
    var providerSymbol: String {
        aiProvider?.menuBarSymbol ?? "?"
    }
}

// MARK: - Menu Bar Quota Display Item

/// A semantic quota metric rendered as one row of a compact menu bar pair.
nonisolated struct MenuBarQuotaMetric: Equatable, Sendable {
    let labelKey: String
    let remainingPercentage: Double
}

/// Two related quota metrics rendered together in the compact menu bar layout.
nonisolated struct MenuBarQuotaPair: Equatable, Sendable {
    let top: MenuBarQuotaMetric
    let bottom: MenuBarQuotaMetric

    static func resolve(for provider: AIProvider, from models: [ModelQuota]) -> MenuBarQuotaPair? {
        switch provider {
        case .claude:
            return makePair(
                from: models,
                topNames: ["five-hour-session"],
                topLabelKey: "quota.metric.fiveHour",
                // 主周额度与 Sonnet/Opus 独立额度不能混成一个周余额。
                bottomNames: ["seven-day-weekly"],
                bottomLabelKey: "quota.metric.weekly"
            )
        case .codex:
            // Spark 是附加能力的独立限额，不得覆盖普通 Codex 的主会话/周额度。
            let sessionNames: Set<String> = ["codex-session"]
            guard let sessionPercentage = minimumPercentage(in: models, named: sessionNames),
                  sessionPercentage >= 0 else {
                return nil
            }
            return makePair(
                from: models,
                topNames: sessionNames,
                topLabelKey: "quota.metric.session",
                bottomNames: ["codex-weekly"],
                bottomLabelKey: "quota.metric.weekly"
            )
        case .amp:
            return makePair(
                from: models,
                topNames: ["amp-agent-usage"],
                topLabelKey: "amp.quota.agent",
                bottomNames: ["amp-orb-usage"],
                bottomLabelKey: "amp.quota.orb",
                requiresBoth: true
            )
        case .antigravity:
            // 仅按上游明确周期分配上下两行；不把模型级剩余量猜成 Session/Weekly。
            // 同一周期内保留最紧张的额度，兼容旧缓存中的四种汇总名称。
            return makePair(
                from: models,
                topNames: Set(models.filter { AntigravityDisplayGroup.window(for: $0) == .session }.map(\.name)),
                topLabelKey: "quota.metric.session",
                bottomNames: Set(models.filter { AntigravityDisplayGroup.window(for: $0) == .weekly }.map(\.name)),
                bottomLabelKey: "quota.metric.weekly"
            )
        case .devin:
            return makePair(
                from: models,
                topNames: ["devin-daily"],
                topLabelKey: "quota.metric.daily",
                bottomNames: ["devin-weekly"],
                bottomLabelKey: "quota.metric.weekly",
                requiresBoth: true
            )
        case .cursor:
            guard models.contains(where: {
                $0.name == "on-demand"
                    && ($0.limit ?? 0) > 0
                    && $0.remaining != nil
                    && $0.percentage >= 0
            }) else {
                return nil
            }
            return makePair(
                from: models,
                topNames: ["plan-usage"],
                topLabelKey: "quota.metric.planUsage",
                bottomNames: ["on-demand"],
                bottomLabelKey: "quota.metric.onDemand",
                requiresBoth: true
            )
        default:
            return nil
        }
    }

    private static func makePair(
        from models: [ModelQuota],
        topNames: Set<String>,
        topLabelKey: String,
        bottomNames: Set<String>,
        bottomLabelKey: String,
        requiresBoth: Bool = false
    ) -> MenuBarQuotaPair? {
        let topPercentage = minimumPercentage(in: models, named: topNames)
        let bottomPercentage = minimumPercentage(in: models, named: bottomNames)

        if requiresBoth {
            guard topPercentage != nil, bottomPercentage != nil else { return nil }
        } else {
            guard topPercentage != nil || bottomPercentage != nil else { return nil }
        }

        return MenuBarQuotaPair(
            top: MenuBarQuotaMetric(
                labelKey: topLabelKey,
                remainingPercentage: topPercentage ?? -1
            ),
            bottom: MenuBarQuotaMetric(
                labelKey: bottomLabelKey,
                remainingPercentage: bottomPercentage ?? -1
            )
        )
    }

    private static func minimumPercentage(in models: [ModelQuota], named names: Set<String>) -> Double? {
        let matching = models.filter { names.contains($0.name) && !$0.isStandaloneMetric }
        guard !matching.isEmpty else { return nil }
        return QuotaPercentagePresentation.lowestRemaining(in: matching) ?? -1
    }
}

/// Data for displaying a single quota item in menu bar
struct MenuBarQuotaDisplayItem: Identifiable, Equatable {
    let id: String
    let providerSymbol: String
    let accountShort: String
    let percentage: Double
    let provider: AIProvider
    var isForbidden: Bool = false
    var quotaPair: MenuBarQuotaPair? = nil
    
    var statusColor: Color {
        statusColor(for: percentage)
    }

    func statusColor(for percentage: Double) -> Color {
        if isForbidden { return .orange }
        if percentage > 50 { return .green }
        if percentage > 20 { return .orange }
        return .red
    }
}

