import Foundation
import CoreFoundation

/// 配额接口的数值与时间转换。百分比字段保持 0...100 口径，比例字段由各解析器明确乘 100，
/// 不根据数值小于 1 猜测单位；布尔、空字符串和非有限值始终表示未知。
nonisolated enum QuotaResponseValue {
    static func number(_ value: Any?) -> Double? {
        if let object = value as? [String: Any] { return number(object["val"]) }
        let result: Double?
        if let value = value as? NSNumber, CFGetTypeID(value) != CFBooleanGetTypeID() {
            result = value.doubleValue
        } else if let text = string(value) { result = Double(text) }
        else { result = nil }
        guard let result, result.isFinite else { return nil }
        return result
    }

    static func string(_ value: Any?) -> String? {
        guard let value = value as? String else { return nil }
        let result = value.trimmingCharacters(in: .whitespacesAndNewlines)
        return result.isEmpty ? nil : result
    }

    /// 仅用于明确的布尔字段，与 CPA 的 booleanValue 接受相同的服务端兼容表示。
    static func boolean(_ value: Any?) -> Bool? {
        if let value = value as? NSNumber, value.doubleValue.isFinite { return value.boolValue }
        guard let text = string(value)?.lowercased() else { return nil }
        if ["true", "1", "yes", "y", "on"].contains(text) { return true }
        if ["false", "0", "no", "n", "off"].contains(text) { return false }
        return nil
    }

    static func object(_ value: Any?) -> [String: Any]? {
        if let value = value as? [String: Any] { return value }
        guard let text = value as? String, let data = text.data(using: .utf8) else { return nil }
        return (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
    }

    /// 只在明确传入时间字段时识别秒／毫秒时间戳，避免把额度或周期误当日期。
    static func resetTime(_ value: Any?, after seconds: Any? = nil, now: Date = Date()) -> String {
        if let text = string(value), Double(text) == nil {
            let fractional = ISO8601DateFormatter()
            fractional.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
            if let date = fractional.date(from: text) ?? ISO8601DateFormatter().date(from: text) {
                return ISO8601DateFormatter().string(from: date)
            }
        }
        if let timestamp = number(value), timestamp > 0, timestamp < 253_402_300_800_000 {
            let seconds = timestamp > 10_000_000_000 ? timestamp / 1000 : timestamp
            return ISO8601DateFormatter().string(from: Date(timeIntervalSince1970: seconds))
        }
        if let seconds = number(seconds), seconds > 0, seconds < 315_576_000 {
            return ISO8601DateFormatter().string(from: now.addingTimeInterval(seconds))
        }
        return ""
    }
}

/// 与 EasyCLIProxyAPI 的请求顺序一致；这里只共享接口地址，不共享或记录任何账号令牌。
nonisolated enum AntigravityQuotaEndpoints {
    static let hosts = [
        "https://daily-cloudcode-pa.googleapis.com",
        "https://daily-cloudcode-pa.sandbox.googleapis.com",
        "https://cloudcode-pa.googleapis.com"
    ]
    static let userAgent = "antigravity/cli/1.0.13 (aidev_client; os_type=darwin; arch=arm64)"
}

/// 从 CPA 凭据元数据提取配额请求所需的项目和账号。原始令牌仅用于本地解码 JWT 声明，
/// 返回值不包含令牌，既不写入统计账本，也不输出到日志。
nonisolated struct CPAQuotaMetadata: Sendable {
    var projectID: String?
    var accountID: String?
    var plan: String?
    var userID: String?

    /// 列表提供的字段已足够路由时直接使用，不要求服务器允许下载完整凭据。
    init(projectID: String? = nil, accountID: String? = nil, plan: String? = nil, userID: String? = nil) {
        self.projectID = QuotaResponseValue.string(projectID)
        self.accountID = QuotaResponseValue.string(accountID)
        self.plan = QuotaResponseValue.string(plan)
        self.userID = QuotaResponseValue.string(userID)
    }

    /// 下载的旧凭据只补全空字段，不能覆盖列表中当前账号的项目、组织或套餐。
    mutating func fillMissing(from other: CPAQuotaMetadata) {
        projectID = projectID ?? other.projectID
        accountID = accountID ?? other.accountID
        plan = plan ?? other.plan
        userID = userID ?? other.userID
    }

    init(data: Data) {
        let root = ((try? JSONSerialization.jsonObject(with: data)) as? [String: Any]) ?? [:]
        var records = [root]
        for key in ["metadata", "attributes", "installed", "web", "tokens"] {
            if let record = QuotaResponseValue.object(root[key]) { records.append(record) }
        }
        let originals = records
        for record in originals {
            for key in ["oauth", "user", "https://api.openai.com/auth"] {
                if let nested = QuotaResponseValue.object(record[key]) { records.append(nested) }
            }
            for key in ["id_token", "idToken"] {
                var payload = QuotaResponseValue.object(record[key])
                if payload == nil, let token = record[key] as? String {
                    let parts = token.split(separator: ".")
                    if parts.count > 1 {
                        var encoded = String(parts[1]).replacingOccurrences(of: "-", with: "+").replacingOccurrences(of: "_", with: "/")
                        encoded += String(repeating: "=", count: (4 - encoded.count % 4) % 4)
                        if let bytes = Data(base64Encoded: encoded) {
                            payload = (try? JSONSerialization.jsonObject(with: bytes)) as? [String: Any]
                        }
                    }
                }
                if let payload {
                    records.append(payload)
                    if let auth = QuotaResponseValue.object(payload["https://api.openai.com/auth"]) { records.append(auth) }
                }
            }
        }
        func first(_ keys: [String]) -> String? {
            for record in records {
                for key in keys { if let value = QuotaResponseValue.string(record[key]) { return value } }
            }
            return nil
        }
        projectID = first(["project_id", "projectId", "gemini_virtual_project", "geminiVirtualProject", "cloudaicompanionProject", "cloudaicompanion_project"])
        accountID = first(["chatgpt_account_id", "chatgptAccountId", "account_id", "accountId"])
        plan = first(["plan_type", "planType", "chatgpt_plan_type", "chatgptPlanType"])
        userID = first(["sub", "subject", "user_id", "userId"])
        if userID == nil {
            for record in originals {
                for key in ["oauth", "user"] {
                    if let nested = QuotaResponseValue.object(record[key]),
                       let id = QuotaResponseValue.string(nested["id"]) { userID = id; break }
                }
                if userID != nil { break }
            }
        }
    }
}

/// 附加画像只补套餐与订阅展示，不改变配额百分比，也不产生客户端 token 或费用统计记录。
nonisolated enum CPAQuotaProfileMapper {
    static func claudePlan(data: Data) -> String? {
        guard let root = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else { return nil }
        let account = QuotaResponseValue.object(root["account"]) ?? [:]
        let organization = QuotaResponseValue.object(root["organization"]) ?? [:]
        let hasMax = QuotaResponseValue.boolean(account["has_claude_max"])
        let hasPro = QuotaResponseValue.boolean(account["has_claude_pro"])
        if hasMax == true { return "Max" }
        if hasPro == true { return "Pro" }
        if QuotaResponseValue.string(organization["organization_type"])?.lowercased() == "claude_team",
           QuotaResponseValue.string(organization["subscription_status"])?.lowercased() == "active" { return "Team" }
        // 只有两个标志都明确为 false 才能判为 Free，缺少画像信息不等于免费套餐。
        return hasMax == false && hasPro == false ? "Free" : nil
    }

    static func antigravityPlan(_ subscription: SubscriptionInfo) -> String? {
        guard subscription.tierId != "unknown" else { return nil }
        return tierNames[subscription.tierId.lowercased()] ?? subscription.tierDisplayName
    }

    private static let tierNames = [
        "free-tier": "Free", "g1-pro-tier": "Pro", "g1-ultra-tier": "Ultra", "g1-ultra-lite-tier": "Ultra Lite"
    ]

    /// 只保留包含有效 id 的 tier，防止空 paidTier 遮蔽有效 currentTier。
    /// 服务端未提供描述或升级文案时使用空值即可，不应因此丢弃已确认的套餐和项目。
    static func antigravitySubscription(data: Data) -> SubscriptionInfo? {
        guard let root = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else { return nil }
        let current = tier(root["currentTier"] ?? root["current_tier"])
        let paid = tier(root["paidTier"] ?? root["paid_tier"])
        let rawProject = root["cloudaicompanionProject"] ?? root["cloudaicompanion_project"]
        let project = QuotaResponseValue.string(rawProject)
            ?? QuotaResponseValue.string(QuotaResponseValue.object(rawProject)?["id"])
        guard current != nil || paid != nil || project != nil else { return nil }
        let allowed = (root["allowedTiers"] ?? root["allowed_tiers"]) as? [Any]
        return SubscriptionInfo(
            currentTier: current,
            allowedTiers: allowed?.compactMap(tier),
            cloudaicompanionProject: project,
            gcpManaged: QuotaResponseValue.boolean(root["gcpManaged"] ?? root["gcp_managed"]),
            upgradeSubscriptionUri: QuotaResponseValue.string(root["upgradeSubscriptionUri"] ?? root["upgrade_subscription_uri"]),
            paidTier: paid
        )
    }

    private static func tier(_ value: Any?) -> SubscriptionTier? {
        guard let record = QuotaResponseValue.object(value), let id = QuotaResponseValue.string(record["id"]) else { return nil }
        let privacy = QuotaResponseValue.object(record["privacyNotice"] ?? record["privacy_notice"])
        return SubscriptionTier(
            id: id,
            name: QuotaResponseValue.string(record["name"]) ?? tierNames[id.lowercased()] ?? id,
            description: QuotaResponseValue.string(record["description"]) ?? "",
            privacyNotice: privacy.map {
                PrivacyNotice(
                    showNotice: QuotaResponseValue.boolean($0["showNotice"] ?? $0["show_notice"]),
                    noticeText: QuotaResponseValue.string($0["noticeText"] ?? $0["notice_text"])
                )
            },
            isDefault: QuotaResponseValue.boolean(record["isDefault"] ?? record["is_default"]),
            upgradeSubscriptionUri: QuotaResponseValue.string(record["upgradeSubscriptionUri"] ?? record["upgrade_subscription_uri"]),
            upgradeSubscriptionText: QuotaResponseValue.string(record["upgradeSubscriptionText"] ?? record["upgrade_subscription_text"]),
            upgradeSubscriptionType: QuotaResponseValue.string(record["upgradeSubscriptionType"] ?? record["upgrade_subscription_type"]),
            userDefinedCloudaicompanionProject: QuotaResponseValue.boolean(record["userDefinedCloudaicompanionProject"] ?? record["user_defined_cloudaicompanion_project"])
        )
    }
}
