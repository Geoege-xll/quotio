import Foundation

/// Claude 直连与 CPA 代理共用的配额口径。utilization/percent 本身是已用百分比，
/// 保留小数并只转换一次；新增独立模型窗口不能被总窗口覆盖。
nonisolated enum ClaudeQuotaMapper {
    static func map(data: Data, updatedAt: Date = Date()) throws -> ProviderQuotaData {
        guard let root = (try JSONSerialization.jsonObject(with: data)) as? [String: Any] else {
            throw QuotaFetchError.invalidResponse
        }
        let limits = root["limits"] as? [[String: Any]] ?? []
        let fableCandidates = limits.filter { limit in
            let scope = limit["scope"] as? [String: Any]
            let model = scope?["model"] as? [String: Any]
            let name = QuotaResponseValue.string(model?["display_name"] ?? model?["displayName"])?.lowercased()
            return QuotaResponseValue.string(limit["kind"])?.lowercased() == "weekly_scoped"
                && (name == "fable" || name == "fable 5") && QuotaResponseValue.number(limit["percent"]) != nil
        }
        let fable = fableCandidates.first { $0["is_active"] as? Bool == true } ?? fableCandidates.first
        let windows = [
            ("five_hour", "five-hour-session", "Session"),
            ("seven_day", "seven-day-weekly", "Weekly"),
            ("seven_day_sonnet", "seven-day-sonnet", "Sonnet"),
            ("seven_day_opus", "seven-day-opus", "Opus"),
            ("seven_day_oauth_apps", "seven-day-oauth-apps", "OAuth Apps · Weekly"),
            ("seven_day_cowork", "seven-day-cowork", "Cowork · Weekly"),
            ("iguana_necktie", "seven-day-fable", "Fable · Weekly")
        ]
        var models: [ModelQuota] = windows.compactMap { key, id, label in
            guard key != "iguana_necktie" || fable == nil,
                  let raw = root[key] as? [String: Any] else { return nil }
            let remaining = QuotaResponseValue.number(raw["utilization"]).map { 100 - min(100, max(0, $0)) } ?? -1
            return ModelQuota(name: id, percentage: remaining,
                resetTime: QuotaResponseValue.resetTime(raw["resets_at"] ?? raw["resetsAt"]), sourceDisplayName: label)
        }
        if let fable, let percent = QuotaResponseValue.number(fable["percent"]) {
            models.append(ModelQuota(name: "seven-day-fable", percentage: 100 - min(100, max(0, percent)),
                resetTime: QuotaResponseValue.resetTime(fable["resets_at"] ?? fable["resetsAt"]), sourceDisplayName: "Fable · Weekly"))
        }
        if let extra = (root["extra_usage"] ?? root["extraUsage"]) as? [String: Any],
           extra["is_enabled"] as? Bool == true || extra["isEnabled"] as? Bool == true {
            let limit = QuotaResponseValue.number(extra["monthly_limit"] ?? extra["monthlyLimit"])
            let used = QuotaResponseValue.number(extra["used_credits"] ?? extra["usedCredits"])
            var remaining = QuotaResponseValue.number(extra["utilization"]).map { 100 - min(100, max(0, $0)) }
            if remaining == nil, let limit, limit > 0, let used, used >= 0 {
                remaining = min(100, max(0, (limit - used) / limit * 100))
            }
            // 上游金额以美分计价，使用货币展示，不能显示成请求次数或把美分当美元。
            var row = ModelQuota(name: "extra-usage", percentage: remaining ?? -1, resetTime: "")
            if let used, used >= 0, let limit, limit > 0 {
                row.presentation = .progress(used: used / 100, limit: limit / 100, unit: .usd)
            }
            models.append(row)
        }
        guard !models.isEmpty else { throw QuotaFetchError.invalidResponse }
        return ProviderQuotaData(models: models, lastUpdated: updatedAt)
    }
}
