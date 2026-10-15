import Foundation
import CoreFoundation

/// 官方文档描述了模型额度和周期，但未公布内部接口的完整 schema。
/// 此处只解析响应中实际出现的字段；缺失额度使用 -1，不推断为 0% 或 100%。
nonisolated enum AntigravityQuotaParser {
    static func models(from data: Data) throws -> [ModelQuota] {
        guard let root = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let models = root["models"] as? [String: Any] else {
            throw QuotaFetchError.invalidResponse
        }
        let result: [ModelQuota] = models.keys.sorted().compactMap { name in
            guard let info = models[name] as? [String: Any],
                  let quota = info["quotaInfo"] as? [String: Any] else { return nil }
            return ModelQuota(
                name: name,
                percentage: percentage(quota["remainingFraction"]),
                resetTime: string(quota["resetTime"]) ?? "",
                sourceDisplayName: string(info["displayName"]) ?? name
            )
        }
        // 空目录不是“额度恢复正常”，应让上层按获取失败处理，保留既有错误语义。
        guard !result.isEmpty else { throw QuotaFetchError.invalidResponse }
        return result
    }

    static func summaryModels(from data: Data) -> [ModelQuota]? {
        guard let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return nil }
        let container = QuotaResponseValue.object(root["response"]) ?? QuotaResponseValue.object(root["summary"])
            ?? QuotaResponseValue.object(root["body"]) ?? root
        guard let groups = container["groups"] as? [[String: Any]] else { return nil }
        var result: [String: ModelQuota] = [:]
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
        return result.values.sorted { $0.name < $1.name }
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
