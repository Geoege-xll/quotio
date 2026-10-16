import Foundation
import CoreFoundation

/// 官方文档描述了模型额度和周期，但未公布内部接口的完整 schema。
/// 此处只解析响应中实际出现的字段；无法确定的额度使用 -1，不推断为满额。
nonisolated enum AntigravityQuotaParser {
    static func models(from data: Data) throws -> [ModelQuota] {
        guard let root = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let models = root["models"] as? [String: Any] else {
            throw QuotaFetchError.invalidResponse
        }
        let result: [ModelQuota] = models.keys.sorted().compactMap { name in
            guard let info = models[name] as? [String: Any],
                  !isDisabled(info["disabled"]),
                  let quota = info["quotaInfo"] as? [String: Any] else { return nil }
            let resetTime = QuotaResponseValue.resetTime(quota["resetTime"])
            // Magpie 对接代码记录了耗尽时 protobuf 省略 remainingFraction 零值的语义。
            // 这里进一步要求存在可解析的显式重置时间才认作活动窗口耗尽；空 {} 仍为未知。
            // 必须仅判断“键缺失”：显式 null、布尔或非有限数即使带时间也不能变成 0%。
            let remaining = quota["remainingFraction"]
            let remainingPercentage = remaining == nil && !resetTime.isEmpty ? 0 : percentage(remaining)
            return ModelQuota(
                name: name,
                percentage: remainingPercentage,
                resetTime: resetTime,
                sourceDisplayName: string(info["displayName"]) ?? name
            )
        }
        // 空目录不是“额度恢复正常”，应让上层按获取失败处理，保留既有错误语义。
        guard !result.isEmpty else { throw QuotaFetchError.invalidResponse }
        return result
    }

    static func summaryModels(from data: Data) -> [ModelQuota]? {
        parseSummary(from: data)?.models
    }

    /// 两种取数入口共用补查条件：只有标准共享组的单一会话桶才有可靠的校准映射。
    /// 未知组或同一组多个独立会话桶仍直接展示原汇总，避免无收益的网络请求与超时等待。
    static func requiresSessionCalibration(from data: Data) -> Bool {
        guard let summary = parseSummary(from: data) else { return false }
        return SessionPool.allCases.contains { pool in
            summary.sessionPools.values.filter { $0 == pool }.count == 1
        }
    }

    /// 周额度仍完全来自汇总；liveModelData 必须由调用方用同一凭据和项目读取。
    /// 现场对照发现 production 的五小时桶可能固定为 100%，且 resetTime 每次查询都向后推五小时；
    /// daily 的 fetchAvailableModels.quotaInfo 才反映实际执行所消耗的五小时额度。
    /// 这里仅校准明确的会话桶，绝不把模型级五小时比例写入周额度，也不读取兼容层 /v1/models。
    /// 补查失败时保留已成功的周额度，把无法核实的标准五小时桶标为未知，不能继续发布假满额。
    static func calibratedModels(summaryData: Data, liveModelData: Data?) -> [ModelQuota]? {
        guard let summary = parseSummary(from: summaryData) else { return nil }
        let liveModels = liveModelData.flatMap { try? models(from: $0) } ?? []
        return calibrateSessionBuckets(summary.models, pools: summary.sessionPools, liveModels: liveModels)
    }

    private struct ParsedSummary {
        let models: [ModelQuota]
        let sessionPools: [String: SessionPool]
    }

    private static func parseSummary(from data: Data) -> ParsedSummary? {
        guard let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return nil }
        let container = QuotaResponseValue.object(root["response"]) ?? QuotaResponseValue.object(root["summary"])
            ?? QuotaResponseValue.object(root["body"]) ?? root
        guard let groups = container["groups"] as? [[String: Any]] else { return nil }
        var result: [String: ModelQuota] = [:]
        var sessionPools: [String: SessionPool] = [:]
        for (groupIndex, group) in groups.enumerated() {
            guard let buckets = group["buckets"] as? [[String: Any]] else { continue }
            let groupName = string(group["displayName"] ?? group["display_name"]) ?? string(group["name"]) ?? "Quota"
            let groupID = string(group["groupId"] ?? group["group_id"]) ?? string(group["id"])
                ?? "\(groupName):\(groupIndex)"
            for (bucketIndex, bucket) in buckets.enumerated() {
                guard !isDisabled(bucket["disabled"]) else { continue }
                // 官方响应允许没有 bucketId，甚至只有 remainingFraction。缺少标识不是坏额度；
                // 仅显式上游 ID 去重，无 ID 条目保留各自位置，防止同名独立池被覆盖。
                let bucketName = string(bucket["displayName"] ?? bucket["display_name"])
                    ?? string(bucket["name"]) ?? string(bucket["window"]) ?? "Quota \(bucketIndex + 1)"
                let bucketID = string(bucket["bucketId"] ?? bucket["bucket_id"]) ?? string(bucket["id"])
                    ?? "\(bucketName):\(bucketIndex)"
                let window = window(from: string(bucket["window"])) ?? window(from: bucketName) ?? window(from: bucketID)
                // 长度前缀使两个 ID 的组合无歧义，同时避免依赖会随响应顺序变化的数组下标。
                let id = "antigravity-bucket:\(groupID.utf8.count):\(groupID)\(bucketID)"
                if let pool = SessionPool(groupName: groupName), window == .session {
                    sessionPools[id] = pool
                }
                let model = ModelQuota(
                    name: id,
                    percentage: percentage(remainingFraction(in: bucket)),
                    resetTime: QuotaResponseValue.resetTime(bucket["resetTime"] ?? bucket["reset_time"] ?? bucket["resetAt"] ?? bucket["reset_at"]),
                    sourceDisplayName: summaryLabel(group: groupName, bucket: bucketName, window: window),
                    antigravityWindow: window
                )
                // 仅相同上游 group/bucket ID 才去重；取最紧张的有效额度，并保留该条重置时间。
                // 不同桶即使显示名称相同也完整保留，不再以 Gemini/Claude 分类覆盖。
                if let previous = result[id] {
                    let previousRank = previous.percentage < 0 ? Double.infinity : previous.percentage
                    let rank = model.percentage < 0 ? Double.infinity : model.percentage
                    if rank < previousRank || (rank == previousRank && model.resetTime < previous.resetTime) {
                        result[id] = model
                    }
                } else {
                    result[id] = model
                }
            }
        }
        // 全部字段未知时继续尝试模型明细接口，不能把无法解析的汇总当作成功数据。
        guard result.values.contains(where: { $0.percentage >= 0 }) else { return nil }
        return ParsedSummary(models: result.values.sorted { $0.name < $1.name }, sessionPools: sessionPools)
    }

    /// 只识别官方明确的共享组和模型 ID 前缀，不把名称相似的独立 Pro／Flash 桶强行合并。
    /// 型号代际来自服务实时返回，规则不依赖任何固定型号清单。
    private enum SessionPool: CaseIterable, Equatable {
        case gemini
        case claudeAndGPT

        init?(groupName: String) {
            switch groupName.lowercased() {
            case "gemini models": self = .gemini
            case "claude and gpt models": self = .claudeAndGPT
            default: return nil
            }
        }

        init?(modelID: String) {
            let id = modelID.lowercased()
            if id.hasPrefix("gemini-") { self = .gemini }
            else if id.hasPrefix("claude-") || id.hasPrefix("gpt-oss-") { self = .claudeAndGPT }
            else { return nil }
        }
    }

    private static func calibrateSessionBuckets(
        _ summary: [ModelQuota], pools: [String: SessionPool], liveModels: [ModelQuota]
    ) -> [ModelQuota] {
        var result = summary
        for pool in SessionPool.allCases {
            let buckets = summary.filter { pools[$0.name] == pool }
            // 两个明确独立的会话桶不能用一组模型读数覆盖；未知组和禁用桶也维持原语义。
            guard buckets.count == 1, let bucket = buckets.first else { continue }
            let models = liveModels.filter { SessionPool(modelID: $0.name) == pool }
            result.removeAll { $0.name == bucket.name }
            guard let first = models.first, models.contains(where: { $0.percentage >= 0 }) else {
                result.append(ModelQuota(
                    name: bucket.name, percentage: -1, resetTime: "",
                    tooltip: "monitor.refresh.failed".localizedStatic(),
                    sourceDisplayName: bucket.sourceDisplayName, antigravityWindow: .session
                ))
                continue
            }
            if models.allSatisfy({ $0.percentage == first.percentage && $0.resetTime == first.resetTime }) {
                // 所有实时模型确实共用同一读数时才保留原共享桶身份、标题和紧凑布局。
                // 百分比与重置时间取自同一条响应，不能把 daily 的额度搭配 production 的滚动时间。
                result.append(ModelQuota(
                    name: bucket.name, percentage: first.percentage, resetTime: first.resetTime,
                    sourceDisplayName: bucket.sourceDisplayName, antigravityWindow: .session
                ))
            } else {
                // 原生模型读数不同或部分未知时保留各自的真实五小时额度，不平均、不随便取一项。
                // 不沿用误导性的共享桶；周桶与其他未知桶均保留，不改变缓存类型或状态宿主。
                result.append(contentsOf: models.map { model in
                    ModelQuota(
                        name: model.name, percentage: model.percentage, resetTime: model.resetTime,
                        sourceDisplayName: (model.sourceDisplayName ?? model.name) + " · " + "quota.metric.fiveHour".localizedStatic(),
                        antigravityWindow: .session
                    )
                })
            }
        }
        return result.sorted { $0.name < $1.name }
    }

    private static func summaryLabel(group: String, bucket: String, window: AntigravityQuotaWindow?) -> String {
        // 官方返回的标题包含 Remaining；Quotio 可切换“已用/剩余”，必须使用中性周期标题，
        // 否则“Weekly Limit Remaining · 24%”会把已用百分比错误描述为剩余百分比。
        let groupLabel: String
        switch group.lowercased() {
        case "gemini models": groupLabel = "Gemini"
        case "claude and gpt models": groupLabel = "Claude / GPT"
        default: groupLabel = group
        }
        let bucketLabel: String
        switch (bucket.lowercased(), window) {
        case ("weekly limit remaining", .weekly): bucketLabel = "quota.metric.weekly".localizedStatic()
        case ("five hour limit remaining", .session): bucketLabel = "quota.metric.fiveHour".localizedStatic()
        default: bucketLabel = bucket
        }
        return groupLabel + " · " + bucketLabel
    }

    private static func remainingFraction(in bucket: [String: Any]) -> Any? {
        if let value = bucket["remainingFraction"] ?? bucket["remaining_fraction"] { return value }
        guard let remaining = bucket["remaining"] as? [String: Any] else { return nil }
        if let value = remaining["remainingFraction"] ?? remaining["remaining_fraction"] { return value }
        return string(remaining["case"]) == "remainingFraction" ? remaining["value"] : nil
    }

    private static func percentage(_ value: Any?) -> Double {
        let number: Double?
        if let text = string(value), text.hasSuffix("%") {
            number = Double(text.dropLast()).map { $0 / 100 }
        } else { number = QuotaResponseValue.number(value) }
        guard let number, number.isFinite else { return -1 }
        return min(1, max(0, number)) * 100
    }

    private static func string(_ value: Any?) -> String? {
        guard let value = value as? String else { return nil }
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    private static func isDisabled(_ value: Any?) -> Bool {
        if let number = value as? NSNumber { return number.boolValue }
        return ["true", "1"].contains(string(value)?.lowercased() ?? "")
    }

    private static func window(from label: String?) -> AntigravityQuotaWindow? {
        guard let label else { return nil }
        let normalized = label.lowercased().replacingOccurrences(of: "_", with: " ")
            .replacingOccurrences(of: "-", with: " ").replacingOccurrences(of: " remaining", with: "")
        // 使用完整周期标签/明确时长，而不是 contains("5") 或 contains("hour")；
        // 例如 model-5、24-hour、1.5-hour、2-week 都不能被误标为标准周期。
        if normalized.range(of: #"^(weekly|week|7d|7 days?|seven days?|604800s)( (limit|quota))?$"#, options: .regularExpression) != nil { return .weekly }
        if normalized.range(of: #"^(session|5h|5 hours?|five hours?|18000s)( (limit|quota))?$"#, options: .regularExpression) != nil { return .session }
        return nil
    }
}
