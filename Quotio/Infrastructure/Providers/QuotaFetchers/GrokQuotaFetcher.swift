import Foundation

nonisolated struct GrokAuthCandidate: Sendable, Equatable {
    let entryKey: String
    let accessToken: String
    let refreshToken: String?
    let idToken: String?
    let clientID: String
    let expiresAt: Date?

    var displayName: String {
        MonitorIdentity.jwtString(idToken, claim: "email") ?? "Grok " + String(entryKey.prefix(8))
    }
}

nonisolated enum GrokQuotaMapper {
    static let weeklyPeriodType = "USAGE_PERIOD_TYPE_WEEKLY"

    static func mapBilling(_ data: Data, plan: String?) -> ProviderQuotaData? {
        mapBillingResponses(weekly: data, monthly: nil, plan: plan)
    }

    /// 与 CPA 的 xai 实现使用相同的两类响应：credits 返回周额度，普通 billing 返回月度计费。
    /// 每个接口可独立成功；缺失百分比保持未知，不能把缺失值当作已用零而显示满额。
    static func mapBillingResponses(weekly: Data?, monthly: Data?, plan: String?) -> ProviderQuotaData? {
        var models: [ModelQuota] = []
        for data in [weekly, monthly].compactMap({ $0 }) {
            guard let body = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { continue }
            let config = body["config"] as? [String: Any] ?? body
            let period = config["current_period"] as? [String: Any]
                ?? config["currentPeriod"] as? [String: Any]
            let periodType = (period?["type"] as? String ?? "").lowercased()
            let weeklyUsed = number(config["credit_usage_percent"] ?? config["creditUsagePercent"])
            let products = config["product_usage"] as? [[String: Any]]
                ?? config["productUsage"] as? [[String: Any]] ?? []
            let reset = resetTime(period?["end"])
            if weeklyUsed != nil || periodType.contains("week") || !products.isEmpty {
                appendUnique(ModelQuota(name: "grok-weekly", percentage: remaining(used: weeklyUsed), resetTime: reset), to: &models)
                for (index, product) in products.enumerated() {
                    let label = trimmed(product["product"] as? String) ?? "Product \(index + 1)"
                    appendUnique(ModelQuota(
                        name: "grok-product-" + label,
                        percentage: remaining(used: number(product["usage_percent"] ?? product["usagePercent"])),
                        resetTime: reset,
                        tooltip: label
                    ), to: &models)
                }
            }

            let limit = number(config["monthly_limit"] ?? config["monthlyLimit"])
            let used = number(config["used"])
            let billingReset = resetTime(config["billing_period_end"] ?? config["billingPeriodEnd"])
            if limit != nil || used != nil {
                let includedUsed = used.map { amount in limit.map { max(0, min(amount, $0)) } ?? max(0, amount) }
                appendUnique(moneyQuota(name: "grok-monthly-included", used: includedUsed, limit: limit, reset: billingReset), to: &models)
            }

            // CPA 支持数值、数值字符串和 { val: ... }，旧 Grok CLI 仍可能返回最后一种形状。
            if let cap = number(config["on_demand_cap"] ?? config["onDemandCap"]) {
                let extraUsed = number(config["on_demand_used"] ?? config["onDemandUsed"])
                    ?? used.flatMap { amount in limit.map { max(0, amount - $0) } }
                if cap > 0, extraUsed != nil {
                    appendUnique(moneyQuota(name: "grok-extra-usage", used: extraUsed, limit: cap, reset: billingReset), to: &models)
                } else {
                    let status = cap > 0
                        ? String(format: "grok.status.cap".localizedStatic(), formatUnits(cap))
                        : "grok.status.disabled".localizedStatic()
                    appendUnique(ModelQuota(name: "grok-extra-usage", percentage: -1, resetTime: billingReset, presentation: .status(text: status)), to: &models)
                }
            }
        }
        guard !models.isEmpty else { return nil }
        return ProviderQuotaData(models: models, lastUpdated: Date(), planType: plan)
    }

    /// 同一窗口可能在两个接口重复出现；有真实数值的结果可以补全先到达的未知状态。
    private static func appendUnique(_ model: ModelQuota, to models: inout [ModelQuota]) {
        if let index = models.firstIndex(where: { $0.name == model.name && $0.resetTime == model.resetTime }) {
            if models[index].percentage < 0, model.percentage >= 0 { models[index] = model }
        } else {
            models.append(model)
        }
    }

    private static func remaining(used: Double?) -> Double {
        used.map { max(0, min(100, 100 - $0)) } ?? -1
    }

    /// billing 的金额单位为美分，展示时转换成美元；只有上限与已用值都存在才构造进度。
    private static func moneyQuota(name: String, used: Double?, limit: Double?, reset: String) -> ModelQuota {
        guard let used, let limit, limit > 0 else {
            return ModelQuota(name: name, percentage: -1, resetTime: reset)
        }
        return ModelQuota(
            name: name,
            percentage: max(0, min(100, (limit - used) / limit * 100)),
            resetTime: reset,
            presentation: .progress(used: used / 100, limit: limit / 100, unit: .usd)
        )
    }

    private static func resetTime(_ value: Any?) -> String {
        guard let string = value as? String, let date = parseDate(string) else { return "" }
        return ISO8601DateFormatter().string(from: date)
    }

    static func planName(_ data: Data) -> String? {
        guard let body = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return nil }
        return trimmed(body["subscription_tier_display"] as? String)
    }

    private static func number(_ value: Any?) -> Double? {
        if let wrapper = value as? [String: Any] { return number(wrapper["val"]) }
        let result: Double?
        switch value {
        case let value as NSNumber:
            // JSON 布尔值会桥接成 NSNumber，不能作为百分比或金额参与计算。
            result = CFGetTypeID(value) == CFBooleanGetTypeID() ? nil : value.doubleValue
        case let value as String: result = Double(value)
        default: result = nil
        }
        return result.flatMap { $0.isFinite ? $0 : nil }
    }

    private static func parseDate(_ value: String) -> Date? {
        let fractional = ISO8601DateFormatter()
        fractional.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return fractional.date(from: value) ?? ISO8601DateFormatter().date(from: value)
    }

    private static func formatUnits(_ value: Double) -> String {
        value.rounded() == value ? String(Int(value)) : String(value)
    }

    private static func trimmed(_ value: String?) -> String? {
        guard let value = value?.trimmingCharacters(in: .whitespacesAndNewlines), !value.isEmpty else { return nil }
        return value
    }
}

actor GrokQuotaFetcher {
    static let authPath = "~/.grok/auth.json"
    static let defaultClientID = "b1a00492-073a-47ea-816f-4c329264a828"

    private let billingURL = URL(string: "https://cli-chat-proxy.grok.com/v1/billing?format=credits")!
    private let monthlyBillingURL = URL(string: "https://cli-chat-proxy.grok.com/v1/billing")!
    private let settingsURL = URL(string: "https://cli-chat-proxy.grok.com/v1/settings")!
    private let refreshURL = URL(string: "https://auth.x.ai/oauth2/token")!
    private var session: URLSession

    init() {
        session = URLSession(configuration: ProxyConfigurationService.createProxiedConfigurationStatic(timeout: 15))
    }

    func updateProxyConfiguration() {
        session = URLSession(configuration: ProxyConfigurationService.createProxiedConfigurationStatic(timeout: 15))
    }

    func fetchAllQuotas() async -> [String: ProviderQuotaData] {
        var results: [String: ProviderQuotaData] = [:]
        for candidate in Self.loadCandidates() {
            if let quota = await fetchQuota(candidate) {
                results[candidate.entryKey] = quota
            }
        }
        return results
    }

    /// Fetches the candidate identified by its stable auth-file entry key.
    func fetchQuota(accountKey: String) async -> ProviderQuotaData? {
        guard let candidate = Self.loadCandidates().first(where: { $0.entryKey == accountKey }) else {
            return nil
        }
        return await fetchQuota(candidate)
    }

    nonisolated static func quotaResult(
        data: Data,
        statusCode: Int,
        plan: String?,
        displayName: String
    ) -> ProviderQuotaData? {
        if statusCode == 401 || statusCode == 403 {
            return ProviderQuotaData(isForbidden: true, accountDisplayName: displayName)
        }
        guard 200...299 ~= statusCode,
              var quota = GrokQuotaMapper.mapBilling(data, plan: plan) else { return nil }
        quota.accountDisplayName = displayName
        return quota
    }

    nonisolated static func loadCandidates(path: String = MonitorIdentity.expand(authPath)) -> [GrokAuthCandidate] {
        guard let data = try? Data(contentsOf: URL(fileURLWithPath: path)),
              let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return [] }
        return root.compactMap { key, raw in
            guard let entry = raw as? [String: Any],
                  let token = trimmed(entry["key"] as? String) else { return nil }
            let entryClientID = trimmed(entry["oidc_client_id"] as? String)
                ?? clientID(fromEntryKey: key)
                ?? defaultClientID
            return GrokAuthCandidate(
                entryKey: key,
                accessToken: token,
                refreshToken: trimmed((entry["refresh_token"] as? String) ?? (entry["refresh"] as? String)),
                idToken: trimmed(entry["id_token"] as? String),
                clientID: entryClientID,
                expiresAt: expiryDate(entry: entry, token: token)
            )
        }.sorted { $0.entryKey < $1.entryKey }
    }

    private nonisolated static func clientID(fromEntryKey key: String) -> String? {
        guard let separator = key.range(of: "::", options: .backwards) else { return nil }
        return trimmed(String(key[separator.upperBound...]))
    }

    private func fetchQuota(_ original: GrokAuthCandidate) async -> ProviderQuotaData? {
        var candidate = original
        if let expiry = candidate.expiresAt, expiry.timeIntervalSinceNow <= 300,
           let refreshed = await refresh(candidate) {
            candidate = refreshed
        }

        var billing = await getBilling(token: candidate.accessToken)
        if Self.isAuthenticationFailure(billing.weekly?.1.statusCode) || Self.isAuthenticationFailure(billing.monthly?.1.statusCode),
           let refreshed = await refresh(candidate) {
            candidate = refreshed
            billing = await getBilling(token: candidate.accessToken)
        }
        // 一类计费接口被拒绝时仍可展示另一接口的有效结果，不让局部失败抹掉整个账号。
        let weeklyData = billing.weekly.flatMap { 200...299 ~= $0.1.statusCode ? $0.0 : nil }
        let monthlyData = billing.monthly.flatMap { 200...299 ~= $0.1.statusCode ? $0.0 : nil }
        guard weeklyData != nil || monthlyData != nil else {
            if Self.isAuthenticationFailure(billing.weekly?.1.statusCode) || Self.isAuthenticationFailure(billing.monthly?.1.statusCode) {
                return ProviderQuotaData(isForbidden: true, accountDisplayName: candidate.displayName)
            }
            return nil
        }

        let plan: String?
        if let (settingsData, settingsResponse) = await get(settingsURL, token: candidate.accessToken),
           200...299 ~= settingsResponse.statusCode {
            plan = GrokQuotaMapper.planName(settingsData)
        } else {
            plan = nil
        }
        guard var quota = GrokQuotaMapper.mapBillingResponses(weekly: weeklyData, monthly: monthlyData, plan: plan) else { return nil }
        quota.accountDisplayName = candidate.displayName
        return quota
    }

    /// 将可选状态码的判断固定为 Int?，避免嵌套元组、可选数组和闭包组合导致类型推断超时。
    /// 没收到响应不等于鉴权失败；只有明确的 401/403 才触发令牌刷新或拒绝状态。
    private nonisolated static func isAuthenticationFailure(_ statusCode: Int?) -> Bool {
        statusCode == 401 || statusCode == 403
    }

    /// 两个 GET 都只查询计费状态，不发送参考客户端的付费健康探测消息。
    private func getBilling(token: String) async -> (weekly: (Data, HTTPURLResponse)?, monthly: (Data, HTTPURLResponse)?) {
        async let weekly = get(billingURL, token: token)
        async let monthly = get(monthlyBillingURL, token: token)
        return await (weekly, monthly)
    }

    private func get(_ url: URL, token: String) async -> (Data, HTTPURLResponse)? {
        var request = URLRequest(url: url)
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        request.setValue("xai-grok-cli", forHTTPHeaderField: "X-XAI-Token-Auth")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue("0.2.91", forHTTPHeaderField: "X-Grok-Client-Version")
        request.setValue("grok-pager/0.2.91 grok-shell/0.2.91 (macos; aarch64)", forHTTPHeaderField: "User-Agent")
        guard let (data, response) = try? await session.data(for: request),
              let http = response as? HTTPURLResponse else { return nil }
        return (data, http)
    }

    private func refresh(_ candidate: GrokAuthCandidate) async -> GrokAuthCandidate? {
        guard let refreshToken = candidate.refreshToken else { return nil }
        let body = "grant_type=refresh_token&client_id=\(Self.formEncoded(candidate.clientID))&refresh_token=\(Self.formEncoded(refreshToken))"
        var request = URLRequest(url: refreshURL)
        request.httpMethod = "POST"
        request.httpBody = Data(body.utf8)
        request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        guard let (data, response) = try? await session.data(for: request),
              let http = response as? HTTPURLResponse,
              200...299 ~= http.statusCode,
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let accessToken = Self.trimmed(json["access_token"] as? String) else { return nil }

        let rotatedRefresh = Self.trimmed(json["refresh_token"] as? String) ?? refreshToken
        let idToken = Self.trimmed(json["id_token"] as? String) ?? candidate.idToken
        let expiresIn = (json["expires_in"] as? NSNumber)?.doubleValue ?? 3600
        let expiresAt = Date().addingTimeInterval(expiresIn)
        do {
            try Self.persistRotatedCredential(
                entryKey: candidate.entryKey,
                accessToken: accessToken,
                refreshToken: rotatedRefresh,
                idToken: idToken,
                expiresAt: expiresAt
            )
        } catch {
            Log.quota("Failed to persist refreshed Grok credential: \(error.localizedDescription)")
        }
        return GrokAuthCandidate(
            entryKey: candidate.entryKey,
            accessToken: accessToken,
            refreshToken: rotatedRefresh,
            idToken: idToken,
            clientID: candidate.clientID,
            expiresAt: expiresAt
        )
    }

    nonisolated static func persistRotatedCredential(
        path: String = MonitorIdentity.expand(authPath),
        entryKey: String,
        accessToken: String,
        refreshToken: String?,
        idToken: String?,
        expiresAt: Date
    ) throws {
        let url = URL(fileURLWithPath: path)
        guard let data = try? Data(contentsOf: url),
              var root = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              var entry = root[entryKey] as? [String: Any] else {
            throw MonitorRuntimeError.invalidCredential
        }
        entry["key"] = accessToken
        if let refreshToken { entry["refresh_token"] = refreshToken }
        if let idToken { entry["id_token"] = idToken }
        entry["expires_at"] = ISO8601DateFormatter().string(from: expiresAt)
        root[entryKey] = entry
        let updated = try JSONSerialization.data(withJSONObject: root, options: [.prettyPrinted, .sortedKeys])
        try SecureAtomicFileWriter.write(updated, to: url)
    }

    private nonisolated static func expiryDate(entry: [String: Any], token: String) -> Date? {
        for key in ["expires_at", "expires"] {
            guard let value = entry[key] as? String else { continue }
            let fractional = ISO8601DateFormatter()
            fractional.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
            if let date = fractional.date(from: value) ?? ISO8601DateFormatter().date(from: value) { return date }
        }
        let pieces = token.split(separator: ".", omittingEmptySubsequences: false)
        guard pieces.count > 1 else { return nil }
        var payload = String(pieces[1]).replacingOccurrences(of: "-", with: "+").replacingOccurrences(of: "_", with: "/")
        payload += String(repeating: "=", count: (4 - payload.count % 4) % 4)
        guard let data = Data(base64Encoded: payload),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let exp = json["exp"] as? NSNumber else { return nil }
        return Date(timeIntervalSince1970: exp.doubleValue)
    }

    private nonisolated static func trimmed(_ value: String?) -> String? {
        guard let value = value?.trimmingCharacters(in: .whitespacesAndNewlines), !value.isEmpty else { return nil }
        return value
    }

    private nonisolated static func formEncoded(_ value: String) -> String {
        value.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed.subtracting(CharacterSet(charactersIn: "+&="))) ?? value
    }
}
